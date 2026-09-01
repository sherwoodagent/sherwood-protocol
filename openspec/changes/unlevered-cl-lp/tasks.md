# Tasks

## 1. Template change

- [ ] 1.1 `InitParams.lpAmount` + mode fork in `_initialize`: both-or-neither
      validation, skip Morpho binding and checks (2)(3)(4) in unlevered mode,
      require `morpho == address(0)` there. Levered path byte-identical.
- [ ] 1.2 `_execute` unlevered branch: pull `lpAmount`, mint; skip
      `_postCollateral` and `morpho.borrow`. TWAP gate, counterparty
      re-check, pool-share cap untouched in both modes.
- [ ] 1.3 Zero-guard EVERY Morpho read: grep the template for `morpho.` and
      `_marketParams`/`marketId` uses (settle `_repayAndWithdraw` position
      read, `undeliveredValue`/`hasUndeliveredValue`, emergency paths) and
      early-return neutral values when `morpho == address(0)`. Sweep-audit,
      not spot-fix — record each site in the PR body.

## 2. Tests (guards mutation-verified: drop one, a test must fail)

- [ ] 2.1 Init matrix: all mixed configs revert; both valid modes init; the
      unlevered config with a nonzero morpho reverts.
- [ ] 2.2 Unlevered lifecycle unit test: execute → rerange → settle with a
      mock pool/adapter and NO Morpho mock wired at all — the strongest
      possible "never calls Morpho" pin, since any call reverts undecodably.
- [ ] 2.3 Levered regression: existing CL suite passes untouched; add one
      test asserting a levered clone's `PositionOpened` event fields are
      unchanged by this diff.
- [ ] 2.4 Fork test (pinned block, vnet): unlevered NVDA/USDG 0.05% position
      — real pool, real position manager; execute, one rerange, settle;
      assert delivery within slippage bounds.
- [ ] 2.5 Invariant/lifecycle harness run with an unlevered clone (pid-22
      style flow).

## 3. Ops (vnet)

- [ ] 3.1 Deploy the (new) CL template build; owner `setTemplateApproval`
      (owner is `0x5A00afAe…` — impersonation on the vnet, real key for any
      future mainnet).
- [ ] 3.2 TierRegistry: confirm swap-adapter ADAPTER standing covers the CL
      template's `_requireAllowedAdapter` binding on this vault (Deploy.s.sol
      already wires it for fresh deployments; the vnet predates the template).

## 4. First real proposal

- [ ] 4.1 Author init params from live state: ±300 ticks around spot,
      re-measured in-range depth, `lpAmount` sized under the pool-share cap,
      rerange policy per the momentum pod (trigger 80%, minInterval, cap).
- [ ] 4.2 Propose on the vnet; guardian fleet reviews; drive the lifecycle
      to execute + settle. This is the fleet's first economically real
      strategy proposal — capture its evidence record.
