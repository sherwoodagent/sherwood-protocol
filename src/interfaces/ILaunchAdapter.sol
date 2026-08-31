// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title ILaunchAdapter
 * @notice Abstraction layer for token launches — a strategy states intent and
 *         invariants; the adapter owns one venue's mechanics. `ISwapAdapter` is
 *         to a swap what this is to an "IPO": the strategy never learns whether
 *         the venue mints to its creator, sells off a bonding curve, or seeds a
 *         pool in the launch transaction.
 *
 *   LIFECYCLE-SHAPED, not a single call, because launchpads disagree about
 *   TIME. Sushi Launchpad V1 mints the token, seeds a one-sided V3 position and
 *   is tradable inside `launch`. StonkBrokers Smart Launch is a process:
 *   create -> arm -> a curve phase lasting minutes to indefinitely -> graduate
 *   -> bond. A `launch() -> tokensOut` surface can express the first and not the
 *   second, so the interface carries `phase`/`finalize` and settlement branches
 *   on the answer.
 *
 *   CUSTODY-SHAPED, because launchpads disagree about ROLES. See the custody
 *   invariant on `launch` — it, not the call shape, is the normative center of
 *   this interface, and it is what an implementation must argue it meets.
 *
 * @dev Implementations are gated by the same `TierRegistry` dual gate swap
 *      adapters are (`isAdapterAllowed` codehash snapshot + tier
 *      certification), and the venue contracts they call hold counterparty
 *      standing. A cloned implementation binds the gate at the IMPLEMENTATION:
 *      consumers verify a clone by ERC-1167 target introspection, so ephemeral
 *      clones need no per-clone registry writes and a demoted implementation
 *      demotes every clone at once.
 */
interface ILaunchAdapter {
    /// @notice What the strategy is asking the venue to do.
    /// @param name          Launch token name.
    /// @param symbol        Launch token symbol.
    /// @param quoteToken    The asset the fund token is paired against. MUST
    ///                      satisfy `quoteSupported`. Chosen per proposal — an
    ///                      agent pairs against whatever the venue supports
    ///                      (WETH, a stable, a stock token, WOOD once its feed
    ///                      is registered), so nothing here may assume WETH.
    /// @param quoteIn       Quote the adapter may pull from the caller and
    ///                      spend at the venue. On a venue that mints the
    ///                      creator nothing (Sushi) this funds the dev buy that
    ///                      IS the reserve, and MUST be nonzero. On a venue
    ///                      that mints to the creator (StonkBrokers) it may be
    ///                      zero — a pure fair launch.
    /// @param minTokensOut  Slippage floor on any same-transaction buy. Never
    ///                      below `reserveAmount` where the buy is the reserve.
    /// @param reserveAmount Launch tokens the STRATEGY must hold when `launch`
    ///                      returns — the pot the fund's holders claim from.
    /// @param deadline      Venue deadline for the launch transaction.
    /// @param feeRecipient  Where the venue's creator fee stream is to be paid,
    ///                      pointed at from the launch itself rather than
    ///                      re-pointed later. Callers pass the FUND'S VAULT.
    ///
    ///                      NAMED AT LAUNCH ON PURPOSE, and it is the whole
    ///                      reason this member exists. Routing fees through the
    ///                      strategy and forwarding them onward gave the fee
    ///                      stream a destination that had to CHANGE when the
    ///                      strategy settled — and while a settled strategy
    ///                      holds fee tokens, anyone can drive the vault's
    ///                      permissionless residue collection and re-stamp a
    ///                      fresh deposit lock on the whole vault. Naming the
    ///                      vault up front deletes that lever rather than
    ///                      guarding it: fees never enter strategy custody in
    ///                      the first place, so there is no lane to get wrong,
    ///                      no handoff to fail at settlement, and no
    ///                      settlement-dependent branch to reason about.
    ///
    ///                      The snapshot machinery is therefore left doing
    ///                      exactly one job — the pro-rata claim on the launch
    ///                      RESERVE — and fees stay a plain vault receipt that
    ///                      a later proposal disposes of.
    /// @param venueData     Venue-specific economics, opaque here. Sushi takes
    ///                      none (the venue fixes price and supply);
    ///                      StonkBrokers takes its `CreateParams` economics —
    ///                      supply, start/graduation market caps, tax schedule,
    ///                      buffer, unsold mode, bond venue, per-wallet cap.
    struct LaunchParams {
        string name;
        string symbol;
        address quoteToken;
        uint256 quoteIn;
        uint256 minTokensOut;
        uint256 reserveAmount;
        uint64 deadline;
        address feeRecipient;
        bytes venueData;
    }

    /// @notice What the venue did.
    /// @param token       The launched ERC-20.
    /// @param launchRef   Venue-scoped key for every later verb. Opaque to the
    ///                    caller by design: Sushi keys by token address,
    ///                    StonkBrokers by `(pad, id)` — a caller that had to
    ///                    know which would be a caller that had to know the
    ///                    venue.
    /// @param reserveHeld Launch tokens now held by the calling strategy.
    /// @param quoteSpent  Quote actually consumed, so the strategy can return
    ///                    the remainder to the vault.
    struct LaunchResult {
        address token;
        bytes32 launchRef;
        uint256 reserveHeld;
        uint256 quoteSpent;
    }

    /// @notice Where a launch is in its venue's lifecycle.
    /// @dev `Live` means a tradable pool exists — immediately on Sushi, only
    ///      after bonding on StonkBrokers. `Failed` is a curve that closed
    ///      without graduating. Settlement branches on this, so it must be
    ///      answerable for every ref an implementation ever issued.
    enum LaunchPhase {
        None,
        Curve,
        Closing,
        Live,
        Failed
    }

    /// @notice Launch a token and hand the strategy its reserve.
    ///
    /// @dev THE CUSTODY INVARIANT — the normative center of this interface.
    ///      When this returns, the CALLING STRATEGY, not the adapter, holds
    ///      `reserveHeld >= p.reserveAmount` launch tokens and the venue's
    ///      creator economics: the fee stream and every creator-only recovery
    ///      lever the venue offers, held directly or through an adapter
    ///      instance the strategy exclusively owns. The adapter itself retains
    ///      no token balance and no role exercisable for any strategy except
    ///      through that strategy's own calls.
    ///
    ///      Adversary: a shared adapter that accumulates creator roles or
    ///      balances becomes one contract whose compromise or mis-accounting
    ///      reaches every tokenized fund at once — the shared-mutable-custody
    ///      shape prior audit rounds kept removing from this codebase. HOW an
    ///      implementation satisfies the invariant is venue-shaped and
    ///      deliberately unconstrained here: a venue with a transferable
    ///      creator role can be a stateless singleton that hands the role back
    ///      in the same transaction; a venue that pins the role at creation
    ///      needs a per-launch instance the strategy owns.
    ///
    ///      Pulls `p.quoteIn` of `p.quoteToken` from `msg.sender`, plus the
    ///      venue's native launch fee per `nativeFeeSource()`. Declared payable
    ///      for implementations that would rather be funded directly, but the
    ///      fee is sourced from tokens precisely so a governor batch never has
    ///      to carry value.
    function launch(LaunchParams calldata p) external payable returns (LaunchResult memory);

    /// @notice Lifecycle position of a launch this adapter issued.
    /// @dev MUST NOT revert, and MUST answer `None` for a ref never issued —
    ///      settlement reads this to decide whether it can finish or must take
    ///      the deliverable maximum, and an unreadable answer there would
    ///      strand the decision, not merely the value.
    function phase(bytes32 launchRef) external view returns (LaunchPhase);

    /// @notice Drive the venue's lifecycle forward where it needs driving.
    /// @dev Graduate/bond on a curve venue; a no-op where the venue completes
    ///      the launch in one transaction. Safe to call in any phase.
    function finalize(bytes32 launchRef) external;

    /// @notice Drive the venue's creator fee payout to the launch's
    ///         `feeRecipient`.
    ///
    /// @dev NEVER PAYS THE CALLER, and never pays the strategy. The destination
    ///      is fixed at launch (see `LaunchParams.feeRecipient`) and cannot be
    ///      re-pointed afterwards, so this verb has ONE destination for the
    ///      life of the launch and no settlement-dependent branch.
    ///
    ///      PERMISSIONLESS on every implementation. Fees are the fund's, the
    ///      payee is fixed, and the venues themselves expose their payout as a
    ///      permissionless call — so anyone may push accrued fees to the vault,
    ///      and a later proposal decides what the vault does with them.
    ///
    ///      Returns `(0, 0)` rather than reverting when nothing has accrued, so
    ///      a caller may invoke it unconditionally.
    function collectFees(bytes32 launchRef) external returns (uint256 quoteOut, uint256 tokenOut);

    /// @notice Whether this venue can pair a launch against `quoteToken`.
    /// @dev MUST NOT revert. The asymmetry between venues lives here and
    ///      nowhere else: Sushi answers from its feed registry (so WOOD is
    ///      false until the venue owner registers a WOOD/USD aggregator, and
    ///      true thereafter with no change here), while a fixed-lane venue
    ///      answers from the lanes it was deployed with.
    function quoteSupported(address quoteToken) external view returns (bool);

    /// @notice The token and amount this adapter will pull from the caller to
    ///         cover the venue's native launch fee — `(address(0), 0)` when the
    ///         venue charges none.
    ///
    /// @dev EXISTS BECAUSE THE PAIR IS THE AGENT'S CHOICE. A venue that charges
    ///      a fee in the chain's native asset has to be funded from tokens the
    ///      strategy holds, and the obvious source — unwrap some of the launch
    ///      quote — silently assumes the quote IS the wrapped native. It is not:
    ///      an agent may pair against a stable, a stock token, or WOOD, and a
    ///      strategy that assumed otherwise would revert at execute on exactly
    ///      the pairings this template exists to enable.
    ///
    ///      So the adapter NAMES its fee source and the strategy acquires it,
    ///      swapping through its own allowlisted swap adapter when the vault
    ///      asset differs. Read live rather than pinned at init: the venue
    ///      owner can reprice the fee between propose and execute, and a
    ///      stale figure would either under-fund the launch or over-pull.
    function nativeFeeSource() external view returns (address token, uint256 amount);

    /// @notice The venue contract this adapter fronts, for counterparty
    ///         standing in the deploy ceremony. `address(0)` where the venue is
    ///         not a single contract.
    ///
    /// @dev NOT A HANDOFF ADDRESS. An earlier design had the strategy call a
    ///      venue-native `transferCreator` here at settlement to move the fee
    ///      stream to the vault; `LaunchParams.feeRecipient` replaced that by
    ///      naming the destination at launch, so no such call exists and one
    ///      would be refused anyway (the strategy is not the creator). Stated
    ///      so a future adapter author does not rebuild the lane.
    function launchTarget() external view returns (address);
}
