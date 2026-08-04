// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IProposerBondEscrow} from "./interfaces/IProposerBondEscrow.sol";

interface IRegistryAuthMinimal {
    function isAuthorizedGovernor(address gov) external view returns (bool);
}

/// @dev The ledger's `coverageFreezer` IS the challenge game — it is the role
///      that freezes a proposal's coverage on a filing and lifts it on a
///      verdict. Read live rather than mirrored here so the two can never
///      drift, and so replacing the game is one `setCoverageFreezer` on the
///      ledger rather than a redeploy of this escrow.
interface ILedgerFreezerMinimal {
    function coverageFreezer() external view returns (address);
}

/**
 * @title ProposerBondEscrow
 * @notice Holds the risk-scaled proposer bond for the lifetime of a proposal.
 *         The proposer is the actual attacker in the threat model, so it posts
 *         capital scaled to what the proposal can extract.
 *
 *         TWO EXITS, AND ONLY TWO. `releaseBond` returns the bond to the
 *         proposer once the proposal reaches a terminal state (the governor
 *         gates WHEN), and `forfeitBond` confiscates it when a challenge
 *         convicts. Neither is discretionary and this contract has NO OWNER: the
 *         release payee is the address recorded at lock time, and the forfeiture
 *         destination is a compile-time constant. The invariant
 *         `wood.balanceOf(this) >= sum of locked-unreleased bonds` holds by
 *         construction; surplus from direct donations is permanently stuck.
 *
 *         BOTH EXITS ARE REQUIRED TOGETHER. `releaseBond` alone would make a
 *         bond recoverable but never losable. Paired with the governor's
 *         one-hour proposer self-settle, a proposer could execute a drain,
 *         settle its own strategy at +1h, reclaim the bond in full and be gone
 *         while the challenge window was still in its first day.
 */
contract ProposerBondEscrow is IProposerBondEscrow {
    using SafeERC20 for IERC20;

    struct Bond {
        address proposer;
        uint96 amount; // WOOD fits in uint96 (total supply << 2^96) — enforced by lockBond's AmountTooLarge guard, not assumed
    }

    /// @dev Integration requirement: WOOD must be a standard ERC20 — no transfer
    ///      fee, no rebasing, no hooks, AND NO BLOCKLIST. A fee-on-transfer token
    ///      would make the escrow insolvent. A blocklisting token is the quieter
    ///      hazard: `releaseBond` pays the RECORDED proposer, so blocklisting that
    ///      address strands the bond permanently — there is no alternate payee and
    ///      no sweep.
    IERC20 public immutable wood;
    IRegistryAuthMinimal public immutable registry;

    /// @notice The singleton exposure ledger whose `coverageFreezer` this escrow
    ///         accepts forfeitures from.
    /// @dev    IMMUTABLE, AND THE LEDGER RATHER THAN THE GAME ITSELF. Pointing
    ///         straight at `ChallengeGame` would be circular at deployment, and
    ///         resolving that circularity is what an owner-set pointer is usually
    ///         for — but an owner able to name the convictor is an owner able to
    ///         name itself and destroy every open bond. The ledger breaks the
    ///         cycle without one: it deploys before both, it already treats the
    ///         game as a privileged role, and rotating that role is guarded on its
    ///         side more strongly than anything this escrow could impose.
    /// @dev Typed `address`, not the narrow interface, so the public getter
    ///      satisfies `IProposerBondEscrow.exposureLedger()` — the type a caller
    ///      comparing it against another address-typed ledger reference needs.
    address public immutable exposureLedger;

    /// @dev Where a forfeited bond goes. Same sink and same constant as
    ///      `ChallengeGame`'s `settleBurnBps`/`forfeitBurnBps` and sWOOD's
    ///      uncompensatable slash residue.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Ceiling on the prosecutor's cut of a forfeited bond, in bps.
    /// @dev    Mirrors the bound sWOOD puts on its own caller-named payout, for
    ///         the same reason: `forfeitBond`'s payee is chosen by the convictor,
    ///         a replaceable role, so the escrow bounds how much of any ONE bond a
    ///         compromised game could send to an address of its choosing. The
    ///         remainder can only ever reach `BURN_ADDRESS`. This is the ONLY
    ///         discretion in the contract.
    uint256 public constant MAX_PROSECUTOR_FEE_BPS = 2_000;

    mapping(bytes32 bondKey => Bond) internal _bonds;

    constructor(address wood_, address registry_, address exposureLedger_) {
        if (wood_ == address(0) || registry_ == address(0) || exposureLedger_ == address(0)) revert ZeroAddress();
        wood = IERC20(wood_);
        registry = IRegistryAuthMinimal(registry_);
        exposureLedger = exposureLedger_;
    }

    modifier onlyGovernor() {
        if (!registry.isAuthorizedGovernor(msg.sender)) revert NotAuthorizedGovernor();
        _;
    }

    function _key(address governor, uint256 proposalId) internal pure returns (bytes32) {
        return keccak256(abi.encode(governor, proposalId));
    }

    /// @inheritdoc IProposerBondEscrow
    /// @dev `proposer` COMES FROM THE CALLER, not from `msg.sender`. Any authorized
    ///      governor can therefore lock a bond against any address that has
    ///      approved this escrow, and agents hold standing approvals in normal
    ///      operation. It is a lockup grief rather than theft — the bond is
    ///      recorded to that address and returns to it — but a compromised or
    ///      buggy governor can freeze a third party's WOOD for the life of a
    ///      proposal it did not consent to.
    function lockBond(uint256 proposalId, address proposer, uint256 amount) external onlyGovernor {
        if (proposer == address(0)) revert ZeroAddress();
        if (amount > type(uint96).max) revert AmountTooLarge();
        bytes32 key = _key(msg.sender, proposalId);
        if (_bonds[key].proposer != address(0)) revert BondAlreadyLocked();
        // casting to 'uint96' is safe: the AmountTooLarge guard above bounds amount <= type(uint96).max
        // forge-lint: disable-next-line(unsafe-typecast)
        _bonds[key] = Bond({proposer: proposer, amount: uint96(amount)});
        wood.safeTransferFrom(proposer, address(this), amount);
        emit BondLocked(msg.sender, proposalId, proposer, amount);
    }

    /// @inheritdoc IProposerBondEscrow
    /// @dev The governor's `reclaimProposerBond` resolves the proposal to a
    ///      TERMINAL state before calling; the escrow does not re-derive lifecycle
    ///      state. Deliberately NOT gated on the live registry check: the bond key
    ///      binds to `msg.sender`, so only the governor that locked a bond can
    ///      address it, and skipping the live check means a later-deauthorized
    ///      governor can still release open bonds to the recorded proposer instead
    ///      of stranding them forever. `lockBond` keeps `onlyGovernor` — that is
    ///      where trust matters.
    function releaseBond(uint256 proposalId) external {
        bytes32 key = _key(msg.sender, proposalId);
        Bond memory b = _bonds[key];
        if (b.proposer == address(0)) revert NoBond();
        delete _bonds[key];
        wood.safeTransfer(b.proposer, b.amount);
        emit BondReleased(msg.sender, proposalId, b.proposer, b.amount);
    }

    /// @inheritdoc IProposerBondEscrow
    /// @dev THE BOND'S DOWNSIDE BRANCH, called from `ChallengeGame._settle` — the
    ///      single point at which a proposal is convicted, by a guilty ruling or
    ///      by the silence verdict. Takes `governor` explicitly rather than
    ///      deriving it from `msg.sender`: the convictor is the challenge game,
    ///      not the governor that locked the bond.
    /// @dev AUTHORIZATION — WHO. `msg.sender` must be the live `coverageFreezer`
    ///      of the wired ledger, which is the challenge game and nothing else. The
    ///      precedent is `StakedWood.slashVerdict`'s `authorizedSlasher`; the
    ///      difference is where the name is kept — sWOOD keeps its own owner-set
    ///      copy, this escrow borrows the ledger's, because a second copy is a
    ///      second thing to keep in step and an owner-set copy here would hand
    ///      this contract the discretionary exit its design refuses. FAILS CLOSED
    ///      when the freezer is unset: an unwired protocol convicts nothing rather
    ///      than letting anyone confiscate.
    /// @dev DESTINATION — WHERE. Burned, less the prosecutor's fee. EVERY
    ///      REACHABLE PAYEE IS A ROUND TRIP:
    ///        - the challenger in FULL: addresses are free, so a proposer could
    ///          file against its own drain and refund itself the whole bond. This
    ///          is why the prosecutor's fee is a BOUNDED slice — at the ceiling a
    ///          self-filing proposer recovers at most 20% and destroys 80%, so the
    ///          round trip loses money on every pass.
    ///        - the vault's LPs: compensation was retired with the escrow; the
    ///          slash is punitive now, and even before, the proposer could hold
    ///          shares and recover its pro-rata slice.
    ///        - a treasury: pays whoever governs, which the attacker may be.
    ///      Destruction is the only sink with no beneficiary to be. It is also why
    ///      the burn destination is a constant and not a parameter.
    /// @dev NO PARTIAL FORFEIT: the whole bond always leaves the proposer. The
    ///      bond is priced at what the proposal could extract and a conviction
    ///      means it extracted, so `feeBps` decides only how much of that loss is
    ///      PAID to the prosecutor rather than burned, never how much the proposer
    ///      keeps.
    /// @dev THE FEE PAYEE IS CALLER-CHOSEN, deliberately, because only the caller
    ///      knows which challenger caused this conviction — but the RATE is not:
    ///      `MAX_PROSECUTOR_FEE_BPS` is enforced here rather than trusted from the
    ///      game, the same way sWOOD re-clamps `slashBpsPer`.
    function forfeitBond(address governor, uint256 proposalId, address feeTo, uint256 feeBps)
        external
        returns (address, uint256)
    {
        if (msg.sender != ILedgerFreezerMinimal(exposureLedger).coverageFreezer()) {
            revert NotAuthorizedConvictor();
        }
        // NOT TRUSTED FROM THE CALLER, for the same reason sWOOD re-checks the
        // rates it is handed: the convictor is a replaceable role, and this
        // contract is the one that actually moves the WOOD. Bounding the rate
        // here is what keeps "a compromised convictor can divert AT MOST
        // `MAX_PROSECUTOR_FEE_BPS` of any one bond" true no matter what the
        // game does. Reverts rather than clamping — a caller-chosen payee must
        // never be laundered into a smaller-but-still-caller-chosen one.
        if (feeBps > MAX_PROSECUTOR_FEE_BPS) revert FeeBpsTooHigh();
        bytes32 key = _key(governor, proposalId);
        Bond memory b = _bonds[key];
        if (b.proposer == address(0)) revert NoBond();
        // Effects before interaction, matching `releaseBond`: the record is
        // gone before any transfer, so a second forfeit (concurrent challenges
        // against the same proposal both reaching a verdict) hits `NoBond`
        // rather than double-burning, and a hooked WOOD cannot re-enter into a
        // still-live bond.
        delete _bonds[key];

        // THE PROSECUTOR'S FEE, AND WHY IT COMES FROM HERE. Catching a bad
        // proposal has to pay someone, and this is the only pot a prosecutor
        // cannot fund for itself: to self-deal you must BE the proposer, and then
        // you are paying yourself a fraction of a bond you forfeit in full. That
        // makes the fee sybil-proof by construction, with no role predicate to
        // game.
        //
        // Deliberately NOT taken from the guardians' slash: that pot IS fundable
        // by a prosecutor willing to stake and approve the proposal it is about to
        // accuse, which is why a slash-funded fee needed an approver-role
        // predicate — and that predicate was controlled by the accused, who could
        // zero the fee by funding their defence from an unrelated address.
        uint256 fee;
        if (feeTo != address(0) && feeBps != 0 && b.amount != 0) {
            fee = (b.amount * feeBps) / 10_000;
            if (fee != 0) {
                wood.safeTransfer(feeTo, fee);
                emit ProsecutorFeePaid(governor, proposalId, feeTo, fee);
            }
        }
        uint256 burned = b.amount - fee;
        if (burned != 0) wood.safeTransfer(BURN_ADDRESS, burned);
        emit BondForfeited(governor, proposalId, b.proposer, b.amount);
        return (b.proposer, b.amount);
    }

    /// @inheritdoc IProposerBondEscrow
    function bondOf(address governor, uint256 proposalId) external view returns (address, uint256) {
        Bond memory b = _bonds[_key(governor, proposalId)];
        return (b.proposer, b.amount);
    }
}
