# Generic-call strategy template

`src/strategies/GenericCallStrategy.sol` lets an agent run a list of calls against any protocol (a Seaport order, a DEX router swap, a lending deposit) without writing Solidity. The agent encodes two call lists; a clone of the template runs them as the proposal's strategy.

> **Unaudited, at the syndicate's own risk.** The template is outside the audit scope, like the concentrated-liquidity and Morpho templates. It is tier 2 for good: it must never be certified at tier 0 or 1, by address or by class ([adapter-onboarding-checklist §2.1](adapter-onboarding-checklist.md)). The template does not limit where funds go. The guardian review does.

Design and normative requirements: [`openspec/changes/generic-call-strategy/`](../openspec/changes/generic-call-strategy/).

## What it does

The clone holds a fixed plan, set once at `initialize`:

| Field | Meaning |
| --- | --- |
| `pullAmount` | Vault asset (USDG) pulled at execute. Zero pulls nothing. |
| `executeCalls` | Calls run, in order, after the pull. |
| `settleCalls` | Calls run, in order, at settle, before custody returns to the vault. |
| `sweepTokens` | ERC-20s pushed to the vault at settle, in addition to the asset. |

`execute()`:

1. Re-checks each target's code against the codehash pinned at init, for both legs.
2. Pulls `pullAmount`.
3. Runs the execute leg.
4. Revokes the grants.

`settle()`:

1. Runs the settle leg.
2. Revokes the grants.
3. Pushes the clone's whole USDG balance and every sweep token to the vault.

If any call fails, the step reverts `CallFailed(leg, index, reason)`, where `leg` is 0 for execute and 1 for settle, and `reason` is the venue's own revert data.

Nothing can be changed after `initialize`: `updateParams` always reverts `NoTunableParams`.

## What an agent supplies

Clone through `StrategyFactory.cloneAndInit(template, vault, proposer, data)` (or the deterministic variant), with:

```solidity
data = abi.encode(
    uint256 pullAmount,
    BatchExecutorLib.Call[] executeCalls,   // (address target, bytes data, uint256 value)
    BatchExecutorLib.Call[] settleCalls,
    address[] sweepTokens
);
```

`Call` is the same struct as a proposal batch call, so the SDK's `BatchCall` type encodes it.

Then propose with the standard batches:

| Leg | Calls | Caps |
| --- | --- | --- |
| Execute | `[USDG.approve(clone, pullAmount), clone.execute()]` | `[0, pullAmount]` |
| Settle | `[clone.settle()]` | `[0]` |

### Rules checked at `initialize`

| Rule | Error |
| --- | --- |
| `value` must be 0. The vault holds no native token and the clone has no `receive`. | `NativeValueUnsupported` |
| A target may not be zero, the clone, the vault, the governor, the SyndicateFactory, the TierRegistry or the StrategyFactory. | `ForbiddenTarget` |
| A target must have code. | `TargetHasNoCode` |
| On the vault asset, only `approve(address,uint256)` and `transfer(address,uint256)` are allowed. | `AssetCallNotAllowed` |
| At most 16 calls per leg. | `TooManyCalls` |
| At most 16,384 bytes of calldata per leg. | `CalldataTooLarge` |
| At most 16 sweep tokens. | `TooManySweepTokens` |

The asset rule is what bounds the loss. During the execute batch the vault's allowance to the clone stays live until the batch ends. Without the rule, a `transferFrom(vault, …)` could spend more than the pull. With it, the clone can only ever lose `pullAmount`.

### Writing legs that work

- **Calldata is fixed when you clone.** Amounts in the settle leg are fixed too. To exit a position whose size you cannot know in advance, either use a venue's "max" sentinel (for example, withdraw `type(uint256).max`) or make execute exact-output so the settle amounts are known.
- **Approvals are revoked after each leg.** If the settle leg needs a venue approval, grant it in the settle leg.
- **Settlement counts only USDG.** Anything returned in another token, and anything left on the clone, is a realised loss in the proposal's P&L. Sell back to USDG in the settle leg. List any token you expect to be left over in `sweepTokens`. The vault owner can move swept tokens to a clone of the same vault (`SyndicateVault.rescueERC20`), where a later proposal can sell them with `pullAmount = 0`.
- **The only price floor is the envelope's.** `settleProposal` refuses a settle below the `maxDrawdownBps` floor. Put venue-level minimums, such as a router's `amountOutMin`, in the calldata.
- **ERC-721s:** a venue may deliver one with `safeTransferFrom`. An NFT the settle leg cannot sell can be pulled to the vault through `rescueERC721To` in an emergency batch. The NFT is then outside the share price. The clone refuses ERC-1155s, because the vault cannot receive them.

## How a guardian reads it

Before you vote:

1. **Provenance.** `StrategyFactory.cloneTemplate(clone)` must equal the address book's `GENERIC_CALL_TEMPLATE`, and `clone.vault()` must be the proposal's vault. A hand-registered look-alike has no `cloneTemplate` entry.
2. **Batches.** The execute batch must be `[USDG.approve(clone, cap), clone.execute()]` and the settle batch `[clone.settle()]`, with `cap >= pullAmount()`.
3. **The plan.** Read these getters:
   - `executeCalls()`, `settleCalls()`, `sweepTokens()`, `pullAmount()`;
   - `grants()`: the approvals the template will revoke;
   - `pinnedCodehash(target)`;
   - `configHash()`, which is `keccak256(abi.encode(pullAmount, executeCalls, settleCalls, sweepTokens))` and can be compared against the proposal's metadata.

   Decode every inner call and ask where funds can go. Both of these pass every template check and are what the review exists to catch:
   - `USDG.transfer(anyone, …)`;
   - a router call that pays an arbitrary address.
4. **Simulate.** Run the execute batch as the governor calling `vault.executeGovernorBatch`, then the settle batch, and read the vault's USDG delta. The simulation is same-block, so it shows no market move between the two legs.

## Tier and coverage

- **Tier.** `tierOf(clone, execute.selector)` is `(2, 10_000)`, so the proposal needs coverage equal to the full cap on `clone.execute()`.
- **Per-call ceiling.** A tier-2 call's cap must also fit under `tier2CallCapBps` of the vault's TVL. Arena vaults need `tier2CallCapBps` of at least 8,000 bps, or a proposal at the Arena size cap reverts `Tier2CallCapExceedsCeiling` at propose (SHE-407).

## Risks

- **No destination limit.** The template does not restrict where funds go. Tier-2 coverage and the guardian vote are the controls.
- **Proxy upgrades are not caught.** A codehash change at a target is caught at execute only. A proxy keeps its codehash when its implementation is swapped, so that swap is not detected. Settle never checks code, so a change can never wedge the return of capital.
- **Approval revocation is best-effort.** It covers ERC-20 `approve` and `setApprovalForAll` only:
  - Permit2, `increaseAllowance` and ERC-777 operators are not revoked;
  - an ERC-721 `approve(to, id)` shares the ERC-20 selector and is skipped.

  The real bound is that the clone only holds what it pulled, and settle empties it.
- **Venue gas is not bounded.** A settle leg too expensive to run leaves the proposal `Executed` until the owner's emergency path recovers custody with `rescueTo` / `rescueERC721To`.
- **The proposer controls settle timing.** The proposer may settle early, as with every template.

## Deployment

The template ships in the `DeployAll` ceremony (`DeployGenericCallStrategy` phase, salt `GENERIC_CALL_TEMPLATE`), and `DeployStrategyFactory` approves it on a fresh deployment.

On a chain that has already been handed off (4663), a `DeployAll` re-run cannot approve it, because the deployer no longer owns the TierRegistry. The live path is three owner-approved steps:

1. Run `script/robinhood-mainnet/DeployGenericCallStrategy.s.sol:DeployGenericCallTemplate` with the deployer key that owns the Create3Factory. It only mints the template.
2. The Safe calls `StrategyFactory.setTemplateApproval(template, true)`.
3. Add `GENERIC_CALL_TEMPLATE` to `chains/4663.json`, and add its line to `script/verify-robinhood.sh`.
