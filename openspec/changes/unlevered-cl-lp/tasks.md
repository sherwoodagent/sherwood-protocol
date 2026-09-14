# Tasks

## 1. Template change

- [x] 1.1 `InitParams.lpAmount` + mode fork in `_initialize`: both-or-neither
      validation, skip Morpho binding and checks (2)(3)(4) in unlevered mode,
      require `morpho == address(0)` there. Levered path byte-identical.
- [x] 1.2 `_execute` unlevered branch: pull `lpAmount`, mint; skip
      `_postCollateral` and `morpho.borrow`. TWAP gate, counterparty
      re-check, pool-share cap untouched in both modes.
- [x] 1.3 Zero-guard EVERY Morpho read: grep the template for `morpho.` and
      `_marketParams`/`marketId` uses (settle `_repayAndWithdraw` position
      read, `undeliveredValue`/`hasUndeliveredValue`, emergency paths) and
      early-return neutral values when `morpho == address(0)`. Sweep-audit,
      not spot-fix — record each site in the PR body.

## 2. Tests (guards mutation-verified: drop one, a test must fail)

- [x] 2.1 Init matrix: all mixed configs revert; both valid modes init; the
      unlevered config carrying levered amounts reverts.
- [x] 2.2 Unlevered lifecycle unit test: execute → rerange → settle with a
      mock pool/adapter and NO Morpho mock wired at all — the strongest
      possible "never calls Morpho" pin, since any call reverts undecodably.
- [x] 2.3 Levered regression: existing CL suite passes untouched; add one
      test asserting a levered clone's `PositionOpened` event fields are
      unchanged by this diff.
- [x] 2.4 Fork test: unlevered position on the live 4663 USDG/WETH venue —
      real pool, real position manager; execute, one rerange, settle; assert
      delivery within slippage bounds. Run against
      `rpc.mainnet.chain.robinhood.com` at latest (the public RPC prunes to a
      ~5k-block window, so the block comes from `ROBINHOOD_FORK_BLOCK`).
- [ ] 2.5 Invariant/lifecycle harness run with an unlevered clone (pid-22
      style flow).

## 3. Ops (vnet)

- [ ] 3.1 Deploy the (new) CL template build; owner `setTemplateApproval`,
      deapprove the superseded template, and RE-ANCHOR the registry's
      `_classAnchors` entry — it is keyed by clone codehash against a template
      codehash, so approval alone leaves the class unanchored. A builder on
      the new ABI reaching a still-approved old template decodes `lpAmount` as
      `tickLower`. (Owner `0x5A00afAe…`: impersonation on the vnet, real key
      for mainnet.) Done once on the vnet for #288's template; this branch
      builds a different one.
- [ ] 3.2 TierRegistry: confirm swap-adapter ADAPTER standing covers the CL
      template's `_requireAllowedAdapter` binding on this vault (Deploy.s.sol
      already wires it for fresh deployments; the vnet predates the template).

## 4. First real proposal

- [x] 4.1 Author init params from live state: ±300 ticks around spot,
      re-measured in-range depth, `lpAmount` sized under the pool-share cap,
      rerange policy per the momentum pod (trigger 80%, minInterval, cap).
- [ ] 4.2 Propose on the vnet; guardian fleet reviews; drive the lifecycle
      to execute + settle. This is the fleet's first economically real
      strategy proposal — capture its evidence record.

> **2.5 / 4.2 status (vnet blocker).** The unlevered strategy simulates to
> full `Success` inside the guardian container (execute→settle, 37 harness
> logs) and the guardian review CLEARS (`outcomeOf == 1`) via the pipeline's
> counterfactual approve. The autonomous Approve VOTE is blocked by a daemon
> operational flake — its forge-in-poll-loop yields `simulation=null` where
> byte-identical args run by hand succeed — on a vnet whose position-manager
> `_nextId` was injected below ~100 poisoned token ids (some execute an
> invalid opcode), so every real v3 mint reverts `ERC721: token already
> minted` until `_nextId` is admin-repaired. Root cause is vnet state
> corruption + warp-induced fork-block drift, not this change. Tracked:
> sherwood-guardian issue + Linear. Needs a fresh unmutated vnet to
> demonstrate the on-chain APPROVE (as pid 22 sandbox did).
