// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IExposureLedger} from "./interfaces/IExposureLedger.sol";

/// @dev Narrow sWOOD read surface (own stake, inbound delegation, delegated
///      slash cap, cooldown). Mirrors the IGovernorMinimal pattern in
///      GuardianRegistry — the ledger does not import the full IStakedWood ABI.
interface ISwoodMinimal {
    function guardianStake(address guardian) external view returns (uint256);
    function delegatedInbound(address delegate) external view returns (uint256);
    function maxDelegatedSlashBps() external view returns (uint256);
    function coolDownPeriod() external view returns (uint256);
}

/**
 * @title ExposureLedger
 * @notice Dollar-denominated coverage accounting for the guardian
 *         economic-security model (spec 2026-07-22 §3.3, §3.3a, §3.7).
 *
 *         `slashableBond(g)` (spec §3.3, precision definition):
 *             ownStake(g) * priceHaircut
 *           + delegatedInbound(g) * maxDelegatedSlashBps/10_000 * priceHaircut
 *         Delegated stake counts ONLY at the delegated-slash cap — a delegated
 *         pool cannot be slashed 100%; counting full vote weight would violate
 *         the coalition inequality at the accounting layer.
 *
 *         Exposure is EPOCH-BUCKETED (spec §3.4a): an approval consumes the
 *         current epoch's bucket; open exposure = the sum of all buckets young
 *         enough that their challenge window has not elapsed. Guardian
 *         commitment per approval is therefore bounded at one epoch + challenge
 *         window regardless of strategy duration.
 *
 * @dev    v1 is WOOD-only (spec §3.7): `woodUsdPriceX8` is a GOVERNANCE-SET
 *         conservative price (<= 30-day low), not an oracle read — no WOOD
 *         Chainlink feed exists on Robinhood Chain (spec §8). Fail-closed: an
 *         unset price values every bond at $0.
 */
contract ExposureLedger is Ownable2Step, IExposureLedger {
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    bytes32 public constant PARAM_CHALLENGE_WINDOW = keccak256("challengeWindow");
    bytes32 public constant PARAM_K_NUMERATOR = keccak256("kNumerator");
    bytes32 public constant PARAM_COVERED_TVL_CAP = keccak256("coveredTvlCapUsd");
    bytes32 public constant PARAM_QUORUM_TIER_THRESHOLD = keccak256("quorumTierThreshold");
    bytes32 public constant PARAM_PROPOSER_BOND_BPS = keccak256("proposerBondBps");

    ISwoodMinimal public immutable swood;
    /// @notice Epoch length (spec §5: 28d initial). Immutable — changing it
    ///         would shift every existing bucket index.
    uint256 public immutable epochLength;
    uint256 public immutable epochGenesis;

    /// @notice Conservative WOOD→USD price, 8 decimals (spec §5 `priceHaircut`).
    uint256 public woodUsdPriceX8;
    /// @notice Post-epoch challenge window (spec §5: 14d initial, single window
    ///         in v1 — per-tier windows are a later refinement).
    uint256 public challengeWindow = 14 days;
    /// @notice k multiplier for the exposure cap (spec §5: k = 1).
    uint256 public kNumerator = 1;
    /// @notice Hard per-vault covered-TVL ceiling in USD-18 (spec §3.7). A
    ///         proposal whose coverage exceeds this cannot be opened. Zero =
    ///         cap unset = NOTHING can be proposed through a wired governor —
    ///         fail-closed until governance seeds it.
    uint256 public coveredTvlCapUsd;
    /// @notice Minimum envelopeTier at which the approve quorum is fail-closed
    ///         (spec §3.3a + §4 gate 2). Launch value 2: tier-2 only. Lowering
    ///         is gated on the §3.10 ROE validation — a BLOCKING launch gate.
    uint8 public quorumTierThreshold = 2;
    /// @notice Proposer bond as bps of USD coverage (spec §3.9/§5). Default 1%.
    uint256 public proposerBondBps = 100;

    address public guardianRegistry;

    constructor(address initialOwner, address swood_, uint256 epochLength_) Ownable(initialOwner) {
        if (swood_ == address(0)) revert ZeroAddress();
        if (epochLength_ == 0) revert InvalidParameter();
        swood = ISwoodMinimal(swood_);
        epochLength = epochLength_;
        epochGenesis = block.timestamp;
    }

    // ── Views ──

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - epochGenesis) / epochLength;
    }

    /// @inheritdoc IExposureLedger
    function slashableBondUsd(address guardian) public view returns (uint256) {
        uint256 own = swood.guardianStake(guardian);
        uint256 inbound = swood.delegatedInbound(guardian);
        uint256 slashableWood = own + (inbound * swood.maxDelegatedSlashBps()) / BPS_DENOMINATOR;
        return (slashableWood * woodUsdPriceX8) / 1e8;
    }

    // ── Owner setters ──

    function setWoodUsdPrice(uint256 newPriceX8) external onlyOwner {
        emit WoodUsdPriceSet(woodUsdPriceX8, newPriceX8);
        woodUsdPriceX8 = newPriceX8;
    }

    function setGuardianRegistry(address registry) external onlyOwner {
        if (registry == address(0)) revert ZeroAddress();
        guardianRegistry = registry;
    }

    function setChallengeWindow(uint256 newWindow) external onlyOwner {
        // Bounded (0, epochLength]: zero would free coverage instantly;
        // beyond one epoch the lookback in openExposureUsd grows unbounded.
        if (newWindow == 0 || newWindow > epochLength) revert InvalidParameter();
        // Cross-contract invariant (spec §5): unstake delay must cover
        // epoch + challenge window, or an approver can unstake before its
        // epoch's approvals can be challenged.
        if (epochLength + newWindow > swood.coolDownPeriod()) revert InvalidParameter();
        emit ParameterChangeFinalized(PARAM_CHALLENGE_WINDOW, challengeWindow, newWindow);
        challengeWindow = newWindow;
    }

    function setKNumerator(uint256 newK) external onlyOwner {
        if (newK == 0) revert InvalidParameter();
        emit ParameterChangeFinalized(PARAM_K_NUMERATOR, kNumerator, newK);
        kNumerator = newK;
    }

    function setCoveredTvlCapUsd(uint256 newCap) external onlyOwner {
        emit ParameterChangeFinalized(PARAM_COVERED_TVL_CAP, coveredTvlCapUsd, newCap);
        coveredTvlCapUsd = newCap;
    }

    function setQuorumTierThreshold(uint8 newThreshold) external onlyOwner {
        if (newThreshold > 3) revert InvalidParameter(); // 3 = quorum disabled for all tiers
        emit ParameterChangeFinalized(PARAM_QUORUM_TIER_THRESHOLD, quorumTierThreshold, newThreshold);
        quorumTierThreshold = newThreshold;
    }

    function setProposerBondBps(uint256 newBps) external onlyOwner {
        if (newBps > BPS_DENOMINATOR) revert InvalidParameter();
        emit ParameterChangeFinalized(PARAM_PROPOSER_BOND_BPS, proposerBondBps, newBps);
        proposerBondBps = newBps;
    }

    // ── Stubs replaced in Tasks 2–4 and 8 (placeholders so each task
    //    compiles and goes green before the next starts — NOT deferred work) ──

    function setAssetFeed(address, address, uint256) external virtual onlyOwner {
        revert InvalidParameter();
    }

    function coverageUsd(address, uint256) public view virtual returns (uint256) {
        revert FeedNotConfigured();
    }

    function proposerBondWood(address, uint256) external view virtual returns (uint256) {
        revert FeedNotConfigured();
    }

    function recordApproval(address, uint256, address) external virtual {
        revert NotGuardianRegistry();
    }

    function releaseApproval(address, uint256, address) external virtual {
        revert NotGuardianRegistry();
    }

    function requireWithinCoveredTvlCap(address, uint256) external view virtual {
        revert CoveredTvlCapExceeded();
    }

    function requireApproveQuorum(address, uint256, address, uint256) external view virtual {
        revert InsufficientApproveCoverage();
    }

    function openExposureUsd(address) public view virtual returns (uint256) {
        return 0;
    }
}
