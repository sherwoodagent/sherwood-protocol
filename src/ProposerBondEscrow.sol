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
 * @notice Holds the risk-scaled proposer bond for the lifetime of a
 *         proposal. The proposer is the actual attacker in the threat
 *         model, so it posts capital scaled to what the proposal can
 *         extract.
 *
 *         TWO EXITS, AND ONLY TWO. `releaseBond` returns the bond to the
 *         proposer once the proposal reaches a terminal state (the governor
 *         gates WHEN — see `SyndicateGovernor.reclaimProposerBond`), and
 *         `forfeitBond` confiscates it when a challenge convicts the proposal.
 *         Neither is discretionary and this contract still has NO OWNER: the
 *         release payee is the address recorded at lock time, and the
 *         forfeiture destination is a compile-time constant. The invariant
 *         `wood.balanceOf(this) >= sum of locked-unreleased bonds` holds by
 *         construction (equality absent direct transfers; surplus from
 *         donations is permanently stuck, accepted for v1a).
 *
 *         BOTH EXITS ARE REQUIRED TOGETHER. `releaseBond` alone would make a
 *         bond recoverable but never losable — a "deterrent" with no
 *         downside branch. Paired with `SyndicateGovernor`'s one-hour
 *         proposer self-settle, a proposer could execute a drain, settle its
 *         own strategy at +1h, reclaim the bond in full and be gone while the
 *         14-day challenge window was still in its first day. A confiscation
 *         function nothing can reach in time changes nothing, and a reclaim
 *         delay with nothing to confiscate at the end of it only
 *         inconveniences the honest.
 */
contract ProposerBondEscrow is IProposerBondEscrow {
    using SafeERC20 for IERC20;

    struct Bond {
        address proposer;
        uint96 amount; // WOOD fits in uint96 (total supply << 2^96) — enforced by lockBond's AmountTooLarge guard, not assumed
    }

    /// @dev Integration requirement: WOOD must be a standard ERC20 — no
    ///      transfer fee, no rebasing, no hooks, AND NO BLOCKLIST.
    ///      A fee-on-transfer token would make the escrow insolvent (recorded
    ///      amounts exceed held balance). A blocklisting token is the quieter
    ///      hazard: `releaseBond` pays the RECORDED proposer, so blocklisting
    ///      that address strands the bond permanently — there is no alternate
    ///      payee and no sweep. Informational while WOOD is in-house, and a
    ///      hard requirement on any future bond token.
    IERC20 public immutable wood;
    IRegistryAuthMinimal public immutable registry;

    /// @notice The singleton exposure ledger whose `coverageFreezer` this
    ///         escrow accepts forfeitures from.
    /// @dev    IMMUTABLE, AND THE LEDGER RATHER THAN THE GAME ITSELF. Pointing
    ///         straight at `ChallengeGame` would be circular at deployment —
    ///         the game must know which escrow holds a proposal's bond and the
    ///         escrow must know which game may take it — and resolving that
    ///         circularity is exactly what an owner-set pointer is usually for.
    ///         This contract does not have an owner and should not grow one for
    ///         this: an owner able to name the convictor is an owner able to
    ///         name itself and destroy every open bond. The ledger breaks the
    ///         cycle without one. It is deployed before both, it is the only
    ///         contract that already treats the game as a privileged role, and
    ///         rotating that role is guarded on its side (`setCoverageFreezer`
    ///         refuses while anything is frozen), which is a
    ///         stronger rotation guard than anything this escrow could impose.
    ILedgerFreezerMinimal public immutable exposureLedger;

    /// @dev Where a forfeited bond goes. Same sink and same constant as
    ///      `ChallengeGame`'s `settleBurnBps`/`forfeitBurnBps` and sWOOD's
    ///      uncompensatable slash residue.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Ceiling on the prosecutor's cut of a forfeited bond, in bps.
    /// @dev    20%, mirroring the bound sWOOD puts on its own caller-named
    ///         payout. It exists for the same reason: `forfeitBond`'s payee is
    ///         chosen by the convictor, a replaceable role, so the escrow
    ///         bounds how much of any ONE bond a compromised game could send to
    ///         an address of its choosing. The remainder can only ever reach
    ///         `BURN_ADDRESS`. This is the ONLY discretion in the contract —
    ///         both exits are otherwise non-discretionary, and the payee is
    ///         bounded rather than free.
    uint256 public constant MAX_PROSECUTOR_FEE_BPS = 2_000;

    mapping(bytes32 bondKey => Bond) internal _bonds;

    constructor(address wood_, address registry_, address exposureLedger_) {
        if (wood_ == address(0) || registry_ == address(0) || exposureLedger_ == address(0)) revert ZeroAddress();
        wood = IERC20(wood_);
        registry = IRegistryAuthMinimal(registry_);
        exposureLedger = ILedgerFreezerMinimal(exposureLedger_);
    }

    modifier onlyGovernor() {
        if (!registry.isAuthorizedGovernor(msg.sender)) revert NotAuthorizedGovernor();
        _;
    }

    function _key(address governor, uint256 proposalId) internal pure returns (bytes32) {
        return keccak256(abi.encode(governor, proposalId));
    }

    /// @inheritdoc IProposerBondEscrow
    /// @dev `proposer` COMES FROM THE CALLER, not from `msg.sender`.
    ///      Any authorized governor can therefore lock a bond against any
    ///      address that has approved this escrow — and agents hold standing
    ///      approvals in normal operation. It is a lockup grief rather than
    ///      theft: the bond is recorded to that address and returns to it on
    ///      release or reclaim, so nothing can be redirected. Governors are
    ///      factory-registered, so the caller set is not open — but a
    ///      compromised or buggy governor can freeze a third party's WOOD for
    ///      the life of a proposal it did not consent to.
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
    ///      TERMINAL state before calling — the escrow does not re-derive
    ///      lifecycle state. Deliberately NOT gated on the live registry
    ///      check: the bond key binds to msg.sender, so only the governor
    ///      that locked a bond can ever address it — a random caller computes
    ///      key(caller, proposalId) and hits NoBond. Skipping the live check
    ///      means a later-deauthorized governor can still release open bonds
    ///      to the recorded proposer instead of stranding them forever.
    ///      `lockBond` keeps onlyGovernor — that is where trust matters.
    function releaseBond(uint256 proposalId) external {
        bytes32 key = _key(msg.sender, proposalId);
        Bond memory b = _bonds[key];
        if (b.proposer == address(0)) revert NoBond();
        delete _bonds[key];
        wood.safeTransfer(b.proposer, b.amount);
        emit BondReleased(msg.sender, proposalId, b.proposer, b.amount);
    }

    /// @inheritdoc IProposerBondEscrow
    /// @dev THE BOND'S DOWNSIDE BRANCH. Called from
    ///      `ChallengeGame._settle`, the single point at which a proposal is
    ///      convicted — by a guilty court ruling or by the silence verdict,
    ///      which say the same thing about the proposal. Takes `governor`
    ///      explicitly rather than deriving it from `msg.sender` the way
    ///      `releaseBond` does: the convictor is the challenge game, not the
    ///      governor that locked the bond, and the game already carries
    ///      `(governor, proposalId)` on the challenge it is settling.
    ///
    /// @dev AUTHORIZATION — WHO. `msg.sender` must be the live
    ///      `coverageFreezer` of the wired ledger, which is the challenge game
    ///      and nothing else. The precedent is `StakedWood.slashToEscrow`'s
    ///      `authorizedSlasher`: one named contract, the one that reaches
    ///      verdicts, may move somebody else's capital. The difference is where
    ///      the name is kept — sWOOD keeps its own owner-set copy, this escrow
    ///      borrows the ledger's, because a second copy of "who is the game"
    ///      is a second thing to keep in step and an owner-set copy here would
    ///      hand this contract the discretionary exit its whole design refuses.
    ///
    ///      FAILS CLOSED when the freezer is unset: `msg.sender` can never be
    ///      `address(0)`, so an unwired protocol convicts nothing rather than
    ///      letting anyone confiscate. That is the correct direction — an
    ///      unreachable forfeiture leaves bonds releasable, while a
    ///      permissive one destroys them.
    ///
    /// @dev DESTINATION — WHERE. Burned, not routed to `CompensationEscrow`:
    ///      `CompensationEscrow.openCase` is `onlyFunder` against a SINGLE
    ///      owner-set funder slot, already held by `StakedWood`. Paying a bond
    ///      into it would mean changing the escrow's access model — a
    ///      contract that custodies LP compensation and is not otherwise
    ///      touched here — which belongs in its own review.
    ///
    ///      Burning is also independently defensible, by the same reasoning
    ///      `forfeitBurnBps` sets out for the challenger bond, applied to a
    ///      party that is by construction the attacker: EVERY REACHABLE PAYEE
    ///      IS A ROUND TRIP.
    ///        - The challenger? Addresses are free. A proposer can file against
    ///          its own drain and refund itself the bond it was supposed to
    ///          lose, at the cost of a challenger bond it also gets back.
    ///        - The vault's LPs, via `CompensationEscrow`? Closest to the
    ///          ideal — but even there the proposer may hold shares and
    ///          recover its pro-rata slice, since the case is apportioned on
    ///          a pre-drain snapshot it could have bought into before
    ///          proposing. Beyond the `onlyFunder` blocker above, `openCase`
    ///          can revert on `EmptySnapshot` / `SnapshotNotPast` /
    ///          `NothingToCompensate`, and it would be reverting inside
    ///          `_settle`, where the caller already treats a failable
    ///          external call as something to wrap rather than trust (see
    ///          the best-effort `demoteByChallenge`).
    ///        - A treasury? Pays whoever governs, which the attacker may be or
    ///          may lobby.
    ///      Destruction is the only sink with no beneficiary to be, so the loss
    ///      falls exactly on whoever forfeited. It is also why this is a
    ///      constant and not a parameter: a caller-chosen destination would
    ///      hand a compromised game the power to redirect bonds to itself,
    ///      which is the specific thing sWOOD refuses when it keeps the
    ///      compensation escrow as owner-set state rather than a
    ///      `slashToEscrow` argument.
    ///
    /// @dev NO PARTIAL FORFEIT, and no bounty carved off the top. The proposer
    ///      bond is priced at what the proposal could extract; a conviction
    ///      means it extracted. Splitting it would reintroduce a payee.
    function forfeitBond(address governor, uint256 proposalId, address feeTo, uint256 feeBps)
        external
        returns (address, uint256)
    {
        if (msg.sender != exposureLedger.coverageFreezer()) revert NotAuthorizedConvictor();
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
        // proposal has to pay someone, and this is the only pot in the protocol
        // that a prosecutor cannot fund for itself: to self-deal you must BE
        // the proposer, and then you are paying yourself a fraction of a bond
        // you forfeit in full — always a net loss while the rate is under
        // 10_000. That makes the fee sybil-proof by construction, with no role
        // predicate to game and no cap to tune.
        //
        // It is deliberately NOT taken from the guardians' slash. That pot is
        // fundable by a prosecutor willing to stake and approve the proposal it
        // is about to accuse, which is why a slash-funded fee needed an
        // approver-role predicate to price the sybil — and that predicate was
        // controlled by the accused, who could zero the fee for free by
        // funding their defence from an unrelated address.
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
