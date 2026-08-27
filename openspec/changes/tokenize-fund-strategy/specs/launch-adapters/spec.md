# launch-adapters

## Purpose

`ILaunchAdapter` abstracts "IPO a token on a launchpad" the way `ISwapAdapter` abstracts "swap": the strategy states intent and invariants; the adapter owns one venue's mechanics. The surface is lifecycle-shaped because launchpads disagree about time — Sushi's launch is one transaction, StonkBrokers' is a curve phase that graduates and bonds later — and it is custody-shaped because launchpads disagree about roles: what must never vary is *who ends up holding what*.

## ADDED Requirements

### Requirement: Lifecycle interface

`src/interfaces/ILaunchAdapter.sol` SHALL expose exactly: `launch(LaunchParams) payable returns (LaunchResult)`, `phase(bytes32) view returns (LaunchPhase)`, `finalize(bytes32)`, `collectFees(bytes32) returns (uint256, uint256)`, `quoteSupported(address) view returns (bool)`, and `launchTarget() view returns (address)`, with the structs and `LaunchPhase` enum (`None, Curve, Closing, Live, Failed`) as given in design Decision 1. `phase` and `quoteSupported` SHALL NOT revert. `LaunchResult.launchRef` SHALL be the venue-scoped key for every later verb; implementations SHALL NOT require callers to know venue keying (pads, ids) directly.

#### Scenario: Phase read on an unknown ref
- **WHEN** `phase(ref)` is called with a ref the adapter never issued
- **THEN** it returns `None` and does not revert

### Requirement: Custody invariant

At the successful end of `launch(p)`, the calling strategy SHALL hold at least `p.reserveAmount` of the launched token, and SHALL hold (directly, or through an adapter instance it exclusively owns) the venue's creator economics: the creator fee stream and every creator-only recovery lever the venue offers. The adapter SHALL retain no token balance and no role exercisable for any strategy other than through that strategy's own calls. `collectFees` SHALL deliver the creator share only to the launch's owning strategy, and SHALL return `(0, 0)` rather than revert when nothing has accrued.

Adversary: a shared adapter that accumulates creator roles or balances becomes a single contract whose compromise or mis-accounting reaches every tokenized fund at once — the shared-mutable-custody shape prior audit rounds removed elsewhere.

#### Scenario: Reserve lands on the strategy
- **WHEN** `launch` returns with `LaunchResult.reserveHeld = r`
- **THEN** `token.balanceOf(strategy) ≥ r ≥ p.reserveAmount`, and `token.balanceOf(adapter) == 0` for a singleton adapter

#### Scenario: Fees cannot be redirected
- **WHEN** any address other than the owning strategy calls `collectFees(ref)`
- **THEN** no value moves to the caller — the call reverts or pays the owning strategy only

### Requirement: Registry gating

Adapter implementations SHALL be admitted through the existing `TierRegistry` dual gate (`setAdapterAllowed` codehash snapshot + tier certification), and the venue contracts each adapter calls (launchpad, pads, lens) SHALL hold counterparty standing. For a cloned adapter, the gate SHALL bind the implementation: a consumer verifies a clone by ERC-1167 target introspection against the allowed implementation address, so ephemeral clones need no per-clone registry writes and a demoted implementation demotes every clone at once.

#### Scenario: Demoted implementation blocks new launches
- **WHEN** the owner clears `setAdapterAllowed(implementation)` and a strategy then reaches `_execute`
- **THEN** the strategy's live adapter re-check fails closed and no capital moves

### Requirement: SushiLaunchAdapter (stateless singleton)

`src/adapters/SushiLaunchAdapter.sol` SHALL front Sushi Launchpad V1 (`launch/launchAndBuy/distributeFees/transferCreator/launchInfo`, verified at `0x104f1ab42674565ec3df0bfebccc4186f72fa7ed` on 4663). `launch` SHALL pull `quoteIn` from the caller, execute `launchAndBuy` with the caller as initial-buy recipient (the dev buy IS the reserve — the venue mints nothing to creators), pay the venue's native launch fee by unwrapping quote WETH (never from a value-carrying governor batch), then `transferCreator(token, msg.sender)` in the same transaction, leaving the singleton role-free and balance-free. `quoteSupported(q)` SHALL mirror `quoteTokenPriceFeed(q) != 0` — WOOD answers false until the venue owner registers a feed. `phase` SHALL report `Live` for every completed launch (the venue mints the pool in-tx); `finalize` is a no-op.

#### Scenario: Reserve equals the dev buy
- **WHEN** `launch(p)` runs with `p.reserveAmount > 0`
- **THEN** the call reverts unless the initial buy delivered `≥ p.reserveAmount` tokens to the strategy (enforced via `minTokensOut ≥ reserveAmount`)

#### Scenario: WOOD quote before feed registration
- **WHEN** `launch(p)` is called with `p.quoteToken = WOOD` while `quoteTokenPriceFeed(WOOD) == 0`
- **THEN** the adapter reverts before moving funds, with an error naming the unsupported quote

### Requirement: StonkLaunchAdapter (per-launch clone)

`src/adapters/StonkLaunchAdapter.sol` SHALL front the Smart Launch V2/V3 pads (`StonkSafeLaunchpadV2`; reads and trade quotes exclusively through `SafeLaunchLensV2` — curve math SHALL NOT be reimplemented). Because the venue pins the creator role at `createLaunch` with no transfer, `launch` SHALL deploy and initialize an ERC-1167 clone owned by the calling strategy; the clone SHALL `createLaunch` (becoming creator), transfer `reserveAmount` of the minted supply to the strategy, and `arm` the remainder. All post-launch verbs on the clone SHALL be owner-only: `finalize` drives `graduate`/`bond` as the phase permits; `collectFees` flushes `flushCreatorQuote` and forwards to the strategy; the venue's `abort` (creator-only, zero-trades-only) SHALL be reachable by the owner as the pre-trade recovery lever. The adapter SHALL never set `eoaOnly`, and SHALL select the pad by quote lane (`quoteSupported` answers per configured pad set — WOOD has no lane and always answers false). `phase` SHALL derive from the venue's launch state (armed/deadline/graduated/bonded/aborted flags), mapping curve-closed-without-graduation to `Failed` pending the on-chain verification in design Open Question 3.

#### Scenario: Reserve withheld before arming
- **WHEN** `launch(p)` runs with supply `S` and `p.reserveAmount = r`
- **THEN** the strategy holds `r`, the pad's launch is armed with `S − r`, and the clone holds nothing but the creator role

#### Scenario: Stock-lane oracle gap
- **WHEN** any adapter verb needs a pad trade while the lane's stock oracle is stale (venue `StalePrice`)
- **THEN** the adapter surfaces the venue revert unchanged; no verb bypasses the gate or retries with a stale-priced path

#### Scenario: Foreign caller on a clone
- **WHEN** any address other than the owning strategy calls a clone's lifecycle verb
- **THEN** the call reverts; the creator role is exercisable only through the owner
