# launch-adapters

## Purpose

`ILaunchAdapter` abstracts "IPO a token on a launchpad" the way `ISwapAdapter` abstracts "swap": the strategy states intent and invariants; the adapter owns one venue's mechanics. The surface is lifecycle-shaped because launchpads disagree about time — Sushi's launch is one transaction, StonkBrokers' is a curve phase that graduates and bonds later — and it is custody-shaped because launchpads disagree about roles: what must never vary is *who ends up holding what*.

## ADDED Requirements

### Requirement: Lifecycle interface

`src/interfaces/ILaunchAdapter.sol` SHALL expose exactly: `launch(LaunchParams) payable returns (LaunchResult)`, `phase(bytes32) view returns (LaunchPhase)`, `finalize(bytes32)`, `collectFees(bytes32) returns (uint256, uint256)`, `quoteSupported(address) view returns (bool)`, `nativeFeeSource() view returns (address, uint256)`, and `launchTarget() view returns (address)`, with the structs and `LaunchPhase` enum (`None, Curve, Closing, Live, Failed`) as given in design Decision 1. `phase`, `quoteSupported` and `nativeFeeSource` SHALL NOT revert.

`nativeFeeSource` SHALL name the token and amount the adapter will pull from the caller to cover the venue's native launch fee, `(address(0), 0)` where the venue charges none, read live rather than pinned so a venue repricing between propose and execute neither under-funds the launch nor over-pulls. Adversary: an adapter that instead unwrapped part of the launch quote would assume the quote is the wrapped native — but the pair is the agent's choice, so that assumption reverts at execute on exactly the stable-, stock- and WOOD-paired launches this template exists to enable. `LaunchResult.launchRef` SHALL be the venue-scoped key for every later verb; implementations SHALL NOT require callers to know venue keying (pads, ids) directly.

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

`src/adapters/SushiLaunchAdapter.sol` SHALL front Sushi Launchpad V1 (`launch/launchAndBuy/distributeFees/transferCreator/launchInfo`, verified at `0x104f1ab42674565ec3df0bfebccc4186f72fa7ed` on 4663). `launch` SHALL pull `quoteIn` from the caller, execute `launchAndBuy` with the caller as initial-buy recipient (the dev buy IS the reserve — the venue mints nothing to creators), pay the venue's native launch fee from the token `nativeFeeSource()` names — WETH, pulled from the caller and unwrapped, never from a value-carrying governor batch and never assumed to be the launch quote — then `transferCreator(token, msg.sender)` in the same transaction, leaving the singleton role-free and balance-free. `quoteSupported(q)` SHALL mirror `quoteTokenPriceFeed(q) != 0` — WOOD answers false until the venue owner registers a feed. Because it unwraps quote WETH to pay that native fee, the adapter SHALL declare a `receive()` restricted to WETH withdrawals (or use a withdraw-to pattern); the strategy SHALL send no value with `launch`.

`phase` and ref validity SHALL derive entirely from venue state — `launchRef` IS the token address and `launchInfo(token)` distinguishes an issued launch from an unknown one — so the singleton keeps no storage and no per-launch bookkeeping. `phase` SHALL report `Live` for every completed launch (the venue mints the pool in-tx) and `None` for a token the venue never issued; `finalize` is a no-op.

Settle-time creator handoff: since the venue pins `transferCreator` to the current creator (the strategy, after launch), the adapter SHALL supply the mechanism rather than perform it — `launchTarget()` plus the ref-is-the-token keying is the whole mechanism, and the strategy's `_settle` calls `transferCreator(token, vault())` on that target so the VAULT becomes the creator and permissionless `distributeFees` pays both legs vault-direct thereafter. The adapter SHALL retain no path to re-take the creator role.

#### Scenario: Reserve equals the dev buy
- **WHEN** `launch(p)` runs with `p.reserveAmount > 0`
- **THEN** the call reverts unless the initial buy delivered `≥ p.reserveAmount` tokens to the strategy (enforced via `minTokensOut ≥ reserveAmount`)

#### Scenario: WOOD quote before feed registration
- **WHEN** `launch(p)` is called with `p.quoteToken = WOOD` while `quoteTokenPriceFeed(WOOD) == 0`
- **THEN** the adapter reverts before moving funds, with an error naming the unsupported quote

### Requirement: StonkLaunchAdapter (per-launch clone)

`src/adapters/StonkLaunchAdapter.sol` SHALL front the Smart Launch V2/V3 pads (`StonkSafeLaunchpadV2`; reads and trade quotes exclusively through `SafeLaunchLensV2` — curve math SHALL NOT be reimplemented). Because the venue pins the creator role at `createLaunch` with no transfer, `launch` SHALL deploy and initialize an ERC-1167 clone owned by the calling strategy; the clone SHALL `createLaunch` (becoming creator), transfer `reserveAmount` of the minted supply to the strategy, and `arm` the remainder. Post-launch verbs on the clone SHALL be gated by WHERE VALUE GOES, not by who calls. `finalize` (`graduate`/`bond`) and `collectFees` (`flushCreatorQuote`, paying the owner) SHALL be permissionless: both are permissionless at the venue itself, the payee is fixed to the owning strategy, and a keeper driving a launch to bond or fees to the fund is a service the fund wants — gating them owner-only would add friction and no safety. The venue's `abort` (creator-only, zero-trades-only) SHALL be owner-only, being a recovery lever whose whole value is that nobody else can pull it. No verb SHALL ever pay the caller. The adapter SHALL never set `eoaOnly`, and SHALL select the pad by quote lane (`quoteSupported` answers per configured pad set — WOOD has no lane and always answers false). That pad set SHALL be immutable: constructor-set on the implementation, with no setter and no owner able to add, remove, or re-point a lane. Adversary: a mutable pad mapping is a routing lever living outside the codehash gate — `setAdapterAllowed` snapshots the implementation's codehash, so a post-certification lane swap would redirect every future launch to an uncertified venue without changing anything the gate can see. Changing lanes means a new implementation and fresh TierRegistry certification.

Because the codehash gate cannot see storage AT ALL, "no setter exists" is a claim a certifier would have to establish by reading the code. The implementation SHALL therefore also expose an IMMUTABLE `padSetHash` over the ordered `(quote, pad)` pairs it was constructed with, so the certified lane set is verifiable on-chain in one read: the codehash pins the code, the pad-set hash pins the configuration that code was certified against, and together they close the gap the adversary above walks through.

`launchRef` SHALL be the clone's own address, and every ref-taking verb SHALL verify by ERC-1167 target introspection that the address is a clone of THIS implementation before trusting it. This keeps the implementation free of per-launch storage — no ref → clone map that could disagree with reality — and makes a forged ref answer `None`/`(0,0)` rather than reaching an attacker-supplied contract.

`phase` SHALL derive from the venue's launch state (armed/deadline/graduated/bonded/aborted flags), mapping curve-closed-without-graduation to `Failed` pending the on-chain verification in design Open Question 3.

The clone SHALL additionally expose `forwardToVault()`: owner-only before the owning strategy settles, permissionless after, flushing `flushCreatorQuote` and sending every clone balance (quote and fund token) to the strategy's vault. This is the post-settlement fee lane — the clone is the creator and is not the strategy, so what it holds is invisible to the vault's residue machinery and what it forwards never passes through strategy custody.

#### Scenario: Reserve withheld before arming
- **WHEN** `launch(p)` runs with supply `S` and `p.reserveAmount = r`
- **THEN** the strategy holds `r`, the pad's launch is armed with `S − r`, and the clone holds nothing but the creator role

#### Scenario: Stock-lane oracle gap
- **WHEN** any adapter verb needs a pad trade while the lane's stock oracle is stale (venue `StalePrice`)
- **THEN** the adapter surfaces the venue revert unchanged; no verb bypasses the gate or retries with a stale-priced path

#### Scenario: Pad set cannot be re-pointed
- **WHEN** anyone attempts to change the implementation's lane → pad mapping after certification
- **THEN** no such entry point exists; serving a new lane requires a new implementation and a fresh `setAdapterAllowed` + certification

#### Scenario: Foreign caller on a clone
- **WHEN** any address other than the owning strategy calls `abort()`, or calls `forwardToVault()` before the owning strategy has settled
- **THEN** the call reverts — the recovery lever is the owner's alone

#### Scenario: Keeper drives a clone's permissionless verbs
- **WHEN** an arbitrary caller invokes `finalize`, `collectFees`, or post-settlement `forwardToVault()`
- **THEN** the call succeeds and every unit of value lands on the owning strategy or its vault; the caller receives nothing

#### Scenario: Forged launch ref
- **WHEN** any ref-taking verb is given an address that is not a clone of this implementation
- **THEN** the ERC-1167 introspection fails and the verb answers `None` / `(0, 0)` without calling the supplied address
