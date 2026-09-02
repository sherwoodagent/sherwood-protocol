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

At the successful end of `launch(p)`, the calling strategy SHALL hold at least `p.reserveAmount` of the launched token, and SHALL hold (directly, or through an adapter instance it exclusively owns) the venue's creator economics: the creator fee stream and every creator-only recovery lever the venue offers. The adapter SHALL retain no token balance and no role exercisable for any strategy other than through that strategy's own calls. `collectFees` SHALL deliver the creator share only to the `feeRecipient` named in `launch`, which callers set to the fund's vault, and SHALL return `(0, 0)` rather than revert when nothing has accrued. In no case SHALL it pay the caller, and in no case SHALL the destination change over the launch's life.

Adversary: a shared adapter that accumulates creator roles or balances becomes a single contract whose compromise or mis-accounting reaches every tokenized fund at once — the shared-mutable-custody shape prior audit rounds removed elsewhere.

#### Scenario: Reserve lands on the strategy
- **WHEN** `launch` returns with `LaunchResult.reserveHeld = r`
- **THEN** `token.balanceOf(strategy) ≥ r ≥ p.reserveAmount`, and `token.balanceOf(adapter) == 0` for a singleton adapter

#### Scenario: Fees cannot be redirected
- **WHEN** any address other than the owning strategy calls `collectFees(ref)`
- **THEN** no value moves to the caller — the payout goes to the `feeRecipient` fixed at launch

#### Scenario: Fees never transit the strategy
- **WHEN** an arbitrary caller invokes `collectFees(ref)`, whether the owning strategy is live or settled
- **THEN** both legs land on the `feeRecipient`, the strategy's balances are unchanged either way, and no deposit lock can be re-stamped off the back of the call

### Requirement: Registry gating

Adapter implementations SHALL be admitted through the existing `TierRegistry` dual gate (`setAdapterAllowed` codehash snapshot + tier certification).

Their venues SHALL NOT additionally require counterparty standing, and the reason is a real difference from `ConcentratedLiquidityStrategy` rather than an omission. That template takes its pool, factory and lending-market addresses from PROPOSER input, so an allowlist is the only thing between a fund and an authority the proposer chose. These adapters take none: every venue address is an IMMUTABLE fixed at construction and verified against the venue itself at deploy time (`launchpad` on Sushi; the constructor-written lane map plus `padSetHash` on StonkBrokers), so the codehash gate already pins them and a counterparty check would be redundant with it. A live end-to-end run confirmed the code matches this — launches execute with no counterparty allowances set — so requiring them would have been ceremony that no code reads. For a cloned adapter, the gate SHALL bind the implementation: a consumer verifies a clone by ERC-1167 target introspection against the allowed implementation address, so ephemeral clones need no per-clone registry writes and a demoted implementation demotes every clone at once.

#### Scenario: A venue cannot drift after certification
- **WHEN** anyone attempts to point a certified adapter at a different venue
- **THEN** no such entry point exists — the venue is immutable, so re-pointing requires a new implementation and fresh certification

#### Scenario: Demoted implementation blocks new launches
- **WHEN** the owner clears `setAdapterAllowed(implementation)` and a strategy then reaches `_execute`
- **THEN** the strategy's live adapter re-check fails closed and no capital moves

### Requirement: SushiLaunchAdapter (stateless singleton)

`src/adapters/SushiLaunchAdapter.sol` SHALL front Sushi Launchpad V1 (`launch/launchAndBuy/distributeFees/transferCreator/launchInfo`, verified at `0x104f1ab42674565ec3df0bfebccc4186f72fa7ed` on 4663). `launch` SHALL pull `quoteIn` from the caller, execute `launchAndBuy` with the caller as initial-buy recipient (the dev buy IS the reserve — the venue mints nothing to creators), pay the venue's native launch fee from the token `nativeFeeSource()` names — WETH, pulled from the caller and unwrapped, never from a value-carrying governor batch and never assumed to be the launch quote — then `transferCreator(token, msg.sender)` in the same transaction, leaving the singleton role-free and balance-free. `quoteSupported(q)` SHALL mirror `quoteTokenPriceFeed(q) != 0` — WOOD answers false until the venue owner registers a feed. Because it unwraps quote WETH to pay that native fee, the adapter SHALL declare a `receive()` restricted to WETH withdrawals (or use a withdraw-to pattern); the strategy SHALL send no value with `launch`.

`phase` and ref validity SHALL derive entirely from venue state — `launchRef` IS the token address and `launchInfo(token)` distinguishes an issued launch from an unknown one — so the singleton keeps no storage and no per-launch bookkeeping. `phase` SHALL report `Live` for every completed launch (the venue mints the pool in-tx) and `None` for a token the venue never issued; `finalize` is a no-op.

Fee destination: `launch` SHALL `transferCreator(token, p.feeRecipient)` in the same transaction, so the FUND'S VAULT is the venue creator from the first block and the permissionless `distributeFees` pays it both legs forever after. The adapter SHALL retain no path to re-take or re-point the role. Two destinations are in play and they are NOT the same one — the dev buy's recipient stays the calling strategy, because the reserve is the strategy's to distribute to snapshot holders; only the fee role goes to the vault. Note what the vault receives is the venue's CREATOR role in full, not merely a fee pointer: it also carries the venue's protocol-reserve levers, which the vault has no verb of its own to exercise. Because the vault holds a transferable role, a governance batch can re-point it — which is the migration recovery path the cloned venue below structurally lacks.

#### Scenario: Reserve equals the dev buy
- **WHEN** `launch(p)` runs with `p.reserveAmount > 0`
- **THEN** the call reverts unless the initial buy delivered `≥ p.reserveAmount` tokens to the strategy (enforced via `minTokensOut ≥ reserveAmount`)

#### Scenario: WOOD quote before feed registration
- **WHEN** `launch(p)` is called with `p.quoteToken = WOOD` while `quoteTokenPriceFeed(WOOD) == 0`
- **THEN** the adapter reverts before moving funds, with an error naming the unsupported quote

### Requirement: PonsLaunchAdapter (stateless singleton, gated venue)

`src/adapters/PonsLaunchAdapter.sol` SHALL front `PonsLaunchFactory` v2 (`0xA5aAb3F0c6EeadF30Ef1D3Eb997108E976351feB`) and its locker (`0x736D76699C26D0d966744cAe304C000d471f7F35`). It SHALL be a SINGLETON, and that is forced rather than chosen: the venue admits launchers by ADDRESS (`whitelistedLaunchers`), so per-launch clones could never each be admitted.

`feeWallet` at this venue decides TWO things — `initialBuyRecipient = feeWallet == 0 ? msg.sender : feeWallet`, and the locker's fee redirect. The template needs them split, so `launch` SHALL set `feeWallet` to the CALLING STRATEGY, so the dev buy that is the reserve lands where holders can claim it, and SHALL then immediately call `locker.setFeeRedirect(token, p.feeRecipient)` in the same transaction, which the locker permits because it authorises `launched.deployer`. The adapter SHALL expose no caller-reachable path to `setFeeRedirect` thereafter: it remains `deployer` forever and therefore retains the theoretical power to re-point any launch's fees, and the custody invariant holds only because that power is unexercisable in fact.

The dev buy is funded in NATIVE here (`initialBuyAmount = msg.value - launchFee`), so the adapter SHALL unwrap `launchFee + quoteIn` of the WETH it pulls, not merely the fee. `quoteSupported` SHALL be CONFIG-gated — true only where some ENABLED launch config pairs against the quote — unlike Sushi's feed registry; only the WETH config is live today, which is a venue configuration rather than a protocol limit. `collectFees` SHALL drive `locker.collectFees`, tolerate its `NoFeesToCollect()` as `(0, 0)`, and report deltas on the current redirect target.

**THE VENUE ENFORCES NO SLIPPAGE FLOOR OF ITS OWN.** The factory hardcodes `amountOutMinimum: 0` into the router call, which inverts the Sushi arrangement — there the venue's own floor fires first and the adapter's check is belt-and-braces. Here the adapter's post-launch balance check is the ONLY thing standing between a proposal's `minTokensOut` and an arbitrarily sandwiched dev buy, so it SHALL check `p.minTokensOut` strictly, with the `reserveAmount` assertion behind it.

`venueData` SHALL carry `{uint256 launchConfigId, uint256 dexId, bytes32 salt}`, each validated before any transfer (in range, enabled, `pairToken == p.quoteToken`, router set). Pinning the ids instead would freeze the adapter at one configuration and force a redeploy plus re-certification the moment Pons adds a pairing.

The salt SHALL be namespaced per caller — `keccak256(abi.encode(msg.sender, salt))`. Adversary, and it is specific to a SINGLETON on this venue: the token address is CREATE2-derived from the metadata and the deployer, and for a shared adapter the deployer is one constant, so two funds choosing the same name, symbol and salt would collide and the second launch would fail. Namespacing gives every strategy its own salt space and makes squatting another fund's launch impossible.

`quoteSupported` SHALL apply TWO gates of different kinds, documented apart so the constraint is not misattributed: the VENUE's, that some enabled config pairs against the quote; and THIS ADAPTER's, that the quote is the wrapped native, because the venue funds the dev buy from `msg.value` and a non-wrapped-native pairing cannot be funded by us at all.

The venue is CLOSED today: `launchToken` reverts `NotWhitelisted` unless `launchEnabled` (false) or the caller is whitelisted, and the v1 factory carries the identical gate under the same owner. The adapter is therefore deployable but INERT until Pons flips the flag or admits our address, and the deploy runbook SHALL say so with the address to hand them. The ONLY approval that gates a Pons proposal on our side is the adapter's own `setAdapterAllowed` plus certification; no counterparty allowance is required, for the same reason as the other two venues — this adapter pins its factory and locker in immutables the codehash gate already covers. The remaining gate is entirely the venue's: the Pons-side whitelist, which no action of ours can substitute for.

#### Scenario: Reserve and fees reach different destinations
- **WHEN** `launch(p)` completes
- **THEN** the launch tokens bought are held by the calling strategy, and the locker's fee redirect for that token is `p.feeRecipient`

#### Scenario: The gate is real
- **WHEN** the adapter is not whitelisted and `launchEnabled` is false
- **THEN** `launch` reverts at the venue and no funds have moved

#### Scenario: Fees cannot be re-pointed after launch
- **WHEN** any caller tries to make the adapter change a launch's fee redirect after `launch` returned
- **THEN** no such entry point exists
### Requirement: A failed venue payout is distinguishable from an empty one

`collectFees` tolerates a failing venue call by contract, but SHALL NOT make that failure invisible. Implementations SHALL emit a distinct event when the inner venue call fails, carrying the revert selector and a gas-starvation indication, while still returning `(0, 0)`.

Adversary, observed live: under an estimated gas limit the inner payout ran out of gas, the outer call returned status 1 with zero logs and moved nothing (224,428 gas), while the identical call with a generous limit moved 8.39 USDG. EIP-150's 63/64 rule lets a child starve while the parent succeeds, so without a signal a keeper cannot tell "the venue refused" from "there was nothing to collect", and a monitored fund silently stops being paid. The selector is read as exactly four bytes of returndata so a hostile venue cannot returndata-bomb a path whose contract is that it must not revert; the gas indication is a heuristic and SHALL be documented as one, never as a detector.

Reported amounts SHALL be measured as balance deltas on the destination, never taken from the venue's return value.

#### Scenario: Starved venue call is visible
- **WHEN** the inner venue payout runs out of gas
- **THEN** the failure event is emitted, the call still returns `(0, 0)`, and it is distinguishable from an honest zero

#### Scenario: Honest zero is quiet
- **WHEN** nothing has accrued and the venue call succeeds
- **THEN** no failure event is emitted

### Requirement: StonkLaunchAdapter (per-launch clone)

`src/adapters/StonkLaunchAdapter.sol` SHALL front the Smart Launch V2/V3 pads (`StonkSafeLaunchpadV2`; reads and trade quotes exclusively through `SafeLaunchLensV2` — curve math SHALL NOT be reimplemented). Because the venue pins the creator role at `createLaunch` with no transfer, `launch` SHALL deploy and initialize an ERC-1167 clone owned by the calling strategy; the clone SHALL `createLaunch` (becoming creator), transfer `reserveAmount` of the minted supply to the strategy, and `arm` the remainder. Post-launch verbs on the clone SHALL be gated by WHERE VALUE GOES, not by who calls. `finalize` (`graduate`/`bond`) and `collectFees` (`flushCreatorQuote`) SHALL be permissionless: both are permissionless at the venue itself, the payee is fixed and is never the caller, and a keeper driving a launch to bond or fees to the fund is a service the fund wants — gating them owner-only would add friction and no safety.

`collectFees` SHALL pay the `feeRecipient` stored at launch, unconditionally — there is no settlement branch and no other destination. Adversary this REMOVES rather than guards: a fee stream that paid the strategy would land value in a settled clone, and until that strategy's residue latch arms, anyone could then drive the vault's permissionless residue collection and re-stamp a fresh `UNVALUED_MAX_LOCK` deposit episode on the whole vault. Naming the recipient at launch means no such balance ever exists, so the lever has no foothold rather than a guard.

Because the codehash gate cannot see storage AT ALL, "no setter exists" is a claim a certifier would have to establish by reading the code. The implementation SHALL therefore also expose an IMMUTABLE `padSetHash` over the ordered `(quote, pad)` pairs it was constructed with, so the certified lane set is verifiable on-chain in one read: the codehash pins the code, the pad-set hash pins the configuration that code was certified against, and together they close the gap the adversary above walks through.

`launchRef` SHALL be the clone's own address, and every ref-taking verb SHALL verify by ERC-1167 target introspection that the address is a clone of THIS implementation before trusting it. This keeps the implementation free of per-launch storage — no ref → clone map that could disagree with reality — and makes a forged ref answer `None`/`(0,0)` rather than reaching an attacker-supplied contract.

`phase` SHALL derive from the venue's launch state (armed/deadline/graduated/bonded/aborted flags plus `openEnded`). VERIFIED ON-CHAIN, not assumed: at this venue **timer expiry is itself a graduation trigger** — the pad's predicate is `timerClose = !openEnded && block.timestamp >= deadline; if (!timerClose && mcap < gradMcap) revert NotGraduatable()`. A non-open-ended curve past its deadline is therefore one permissionless `graduate()` away from a locked pool, and SHALL map to `Closing`, never to `Failed`. The boundary is exclusive: at exactly `deadline` the venue has already barred trades and already permits the close. `Failed` at this venue means `aborted` and ONLY `aborted`, which the venue permits only before the first buy — so it is a narrow, early-window outcome and any settlement branch written for "closed without graduating" is dead code here.

`bufferSecs` is an OPENING anti-snipe shield, not a post-window grace period: `arm` sets `deadline = armTime + bufferSecs + windowSecs`, and the first `bufferSecs` trade at a 99.99% tax. A proposal's effective trading window is `bufferSecs + windowSecs`.

The clone SHALL store `feeRecipient` at initialization and reject a zero value. `collectFees` SHALL move the clone's ENTIRE balance of both the lane quote and the launch token to that recipient, not merely what the venue's flush produced — those are the only two assets any path in the adapter can leave on a clone, so this doubles as the permissionless sweep and nothing can be stranded. It SHALL make no call into the owner at all, so an owner that reverts, returns short, or ceases to exist cannot influence where fees go or whether they move. `abort()` remains owner-only and returns recovered supply to the OWNER, not the fee recipient — recovered supply is the fund's launch allocation, not fee income.

The destination is IMMUTABLE for the clone's life. That is deliberate — a settable recipient is a creator-role transfer by another name — but it is a real loss of a recovery path: unlike the Sushi venue, where the vault holds a transferable role a governance batch can re-point, a fund that migrates vaults leaves its Stonk clones forwarding to the old one forever.

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
- **WHEN** any address other than the owning strategy calls `abort()`
- **THEN** the call reverts — the recovery lever is the owner's alone

#### Scenario: Keeper drives a clone's permissionless verbs
- **WHEN** an arbitrary caller invokes `finalize` or `collectFees`
- **THEN** the call succeeds, every unit of value lands on the launch's fixed destination, and the caller receives nothing

#### Scenario: Forged launch ref
- **WHEN** any ref-taking verb is given an address that is not a clone of this implementation
- **THEN** the ERC-1167 introspection fails and the verb answers `None` / `(0, 0)` without calling the supplied address
