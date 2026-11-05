// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC20Mock} from "./ERC20Mock.sol";

/// @notice Deposit venue for generic-call tests: pulls on `deposit`, pays back (plus optional yield) on `withdraw`.
contract MockCallVenue {
    mapping(address token => mapping(address depositor => uint256)) public deposited;

    function deposit(address token, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        deposited[token][msg.sender] += amount;
    }

    function withdraw(address token, uint256 amount) external {
        deposited[token][msg.sender] -= amount;
        IERC20(token).transfer(msg.sender, amount);
    }

    /// @notice Pays `amount` back plus `yield_` freshly minted `token`.
    function withdrawWithYield(address token, uint256 amount, uint256 yield_) external {
        deposited[token][msg.sender] -= amount;
        ERC20Mock(token).mint(msg.sender, yield_);
        IERC20(token).transfer(msg.sender, amount);
    }

    /// @notice Pays `amount` of `token` back and `bonus` of a minted `bonusToken`.
    function withdrawWithBonus(address token, uint256 amount, address bonusToken, uint256 bonus) external {
        deposited[token][msg.sender] -= amount;
        ERC20Mock(bonusToken).mint(msg.sender, bonus);
        IERC20(token).transfer(msg.sender, amount);
    }

    /// @notice Spends an allowance `from` granted this venue, as a hostile venue would after the leg.
    function pull(address token, address from, uint256 amount) external {
        IERC20(token).transferFrom(from, address(this), amount);
    }
}

/// @notice Same behaviour as `MockCallVenue`, different bytecode: stands in for a redeploy at the same address.
contract MockCallVenueV2 is MockCallVenue {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @notice A venue whose call always fails with a decodable error.
contract RevertingVenue {
    error Boom(uint256 code);

    function fail(uint256 code) external pure {
        revert Boom(code);
    }
}

/// @notice ERC-20 whose `approve(_, 0)` reverts: the revoke step must not wedge on it.
contract NoZeroApproveToken is ERC20Mock {
    constructor() ERC20Mock("NoZero", "NZ", 18) {}

    function approve(address spender, uint256 value) public override returns (bool) {
        require(value != 0, "no zero approve");
        return super.approve(spender, value);
    }
}

/// @notice ERC-20 whose zero-value `transferFrom` reverts, as some tokens do.
contract NoZeroTransferToken is ERC20Mock {
    constructor() ERC20Mock("NoZeroTransfer", "NZT", 6) {}

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        require(value != 0, "zero transfer");
        return super.transferFrom(from, to, value);
    }
}

contract MockNFT is ERC721 {
    constructor() ERC721("Mock NFT", "MNFT") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

/// @notice Fixed-price NFT market: sells with `safeTransferFrom`, buys back with `transferFrom`.
contract MockNftMarket {
    MockNFT public immutable nft;
    IERC20 public immutable payToken;
    bool public closed;

    constructor(MockNFT nft_, IERC20 payToken_) {
        nft = nft_;
        payToken = payToken_;
    }

    function setClosed(bool c) external {
        closed = c;
    }

    function buy(uint256 id, uint256 price) external {
        payToken.transferFrom(msg.sender, address(this), price);
        nft.safeTransferFrom(address(this), msg.sender, id);
    }

    function sell(uint256 id, uint256 price) external {
        require(!closed, "market closed");
        nft.transferFrom(msg.sender, address(this), id);
        payToken.transfer(msg.sender, price);
    }
}

contract GCGuardianRegistryStub {
    address public swood;

    constructor(address swood_) {
        swood = swood_;
    }

    function setSwood(address s) external {
        swood = s;
    }
}

contract GCRegistryStub {
    address public strategyFactory;

    function setStrategyFactory(address f) external {
        strategyFactory = f;
    }
}

/// @notice Governor stand-in: answers the binding walk with one active proposal whose strategy is settable.
contract GCGovernorStub {
    address public tierRegistry;
    address public guardianRegistry;
    address public exposureLedger;
    address public activeStrategy;

    constructor(address registry) {
        tierRegistry = registry;
    }

    function setGuardianRegistry(address r) external {
        guardianRegistry = r;
    }

    function setExposureLedger(address l) external {
        exposureLedger = l;
    }

    function setActiveStrategy(address s) external {
        activeStrategy = s;
    }

    function getActiveProposal() external pure returns (uint256) {
        return 1;
    }

    function strategyOf(uint256) external view returns (address) {
        return activeStrategy;
    }
}

contract GCVaultStub {
    address public asset;
    address public governor;
    address public factory;
    address public withdrawalQueue;

    constructor(address asset_, address governor_, address factory_) {
        asset = asset_;
        governor = governor_;
        factory = factory_;
    }

    function setGovernor(address g) external {
        governor = g;
    }

    function setFactory(address f) external {
        factory = f;
    }

    function setWithdrawalQueue(address q) external {
        withdrawalQueue = q;
    }

    function isAgent(address) external pure returns (bool) {
        return true;
    }
}

/// @notice Swap at a settable rate (`out = in * rate / 1e18`), minting the output token.
contract MockRateSwap {
    mapping(address tokenIn => mapping(address tokenOut => uint256)) public rate;

    function setRate(address tokenIn, address tokenOut, uint256 r) external {
        rate[tokenIn][tokenOut] = r;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn) external returns (uint256 out) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        out = (amountIn * rate[tokenIn][tokenOut]) / 1e18;
        ERC20Mock(tokenOut).mint(msg.sender, out);
    }
}
