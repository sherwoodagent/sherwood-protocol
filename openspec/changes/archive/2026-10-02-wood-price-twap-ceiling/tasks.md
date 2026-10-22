# Tasks

> ## ⚠️ TASKS 4, 4a, 7a AND 9 ARE SUPERSEDED — read `design-revision-2026-08-01.md`
>
> They describe the two-number model (`woodFallbackPriceX8` plus a ceiling),
> which revision 2 deleted. What actually shipped, and how each differs:
>
> - **4** — the resolution order is `feed fresh ? min(feed, cap) : twap fresh ?
>   min(twap, cap) : revert NoWoodPrice`. The cap is never served as a price, so
>   there is no "fallback" branch left to order. `woodPriceDetail()` returns
>   `(price, fromFeed, capBinding)`.
> - **4a** — `woodFallbackPriceX8` was NOT added. Deleting it *is* the change.
> - **4c** — resolved by finding 7: a zero cap now REVERTS rather than driving
>   the price to zero, so the `effectiveTotal == 0` hazard this task worried
>   about is unreachable through the emergency stop.
> - **7a** — the pre-flight asserts `woodUsdPriceX8 != 0` AND that the composed
>   `woodPriceX8()` resolves. The second half is the one that matters: a
>   cap-only assert passes a deployment with nothing priced beneath the cap.
> - **9** — `docs/robinhood-fork-deployment.md` was deleted by PR #85 (docs
>   migrated to OpenSpec). That content now lives in
>   `openspec/specs/deployment-docs/spec.md` and was updated there.
>
> Tasks 1, 2, 3, 5, 6, 8 and 10 stand as written.

- [x] 1. ~~Verify the fork before building anything.~~ **DONE 2026-08-01 —
  proven standard by CREATE2 derivation** (see design.md risks). The pair at
  `0xBF3BB81de6285b8310A028d1C2Cd38F9419d54C1` reproduces exactly from the
  canonical Uniswap V2 init-code hash under factory
  `0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f`, so `_update`, the UQ112x112
  cumulatives and the 2^32 timestamp wrap are all standard. No deviation; the
  change rests on solid ground. **Re-run this derivation if the pair address
  ever changes** — it is a one-command check.
- [x] 2. Re-read the live reserves and ETH/USD answer; update design.md's
  measured block if they have moved materially.
- [x] 3. `src/pricing/WoodTwapOracle.sol`: permissionless `update()` storing
  `(cumulative, timestamp)`; `view consult()` returning
  `(uint256 twapUsdX8, bool ok)`; window + `maxTwapAge` bounded setters; USD
  conversion via the ETH/USD feed with the same staleness treatment used
  elsewhere in the ledger.
- [x] 4. `src/ExposureLedger.sol`: implement the option-A resolution order in
  `_woodPrice` — `source = twap fresh ? twap : (fallback != 0 ? fallback :
  revert NoWoodPrice)`, then `_haircut(min(source, woodUsdPriceX8))`. Wire the
  oracle with the `code.length` + `try/catch` protection `_woodPrice` already
  uses for feeds, and extend `woodPriceDetail()` per the spec delta.
- [x] 4a. Add `woodFallbackPriceX8` + its setter (maintained, conservative;
  rate-limit upward moves for the same anti-pump reason `setWoodUsdPrice`
  does, but do not inherit the 1-day interval on downward moves — a maintained
  price needs to be able to track a fall promptly).
- [x] 4b. DEFERRED — filed as issue #89 (alters live emergency semantics; does not belong in an oracle PR). Consider relaxing `MIN_PRICE_UPDATE_INTERVAL` for *downward*
  `setWoodUsdPrice` moves. The interval exists to stop the 2^N pump (review
  M4), which is an upward-only concern; gating downward moves makes the
  emergency brake usable once per day, which is not what a brake should be.
- [x] 4c. **Cross-check before relying on `woodUsdPriceX8 = 0` as the kill
  switch.** With the `min` in place, a zero ceiling drives the price to zero,
  and the 2026-08-01 audit found `effectiveTotal == 0` marks a challenge
  convicted while recovering nothing and blocking re-filing. Either fix that
  path first or document that the emergency stop should be a small non-zero
  value rather than literal zero.
- [x] 5. Interfaces + layout goldens (`./script/check-layout-goldens.sh`),
  since `ExposureLedger` gains storage.
- [x] 6. Tests — failing-first where feasible, one per spec scenario. Include:
  ceiling binds only downward; stale snapshot degrades rather than reverts;
  codeless/reverting oracle degrades; ETH/USD stale degrades; permissionless
  `update()`; window bounds rejected; unwire works. Repo gotchas: use
  `vm.getBlockTimestamp()` rather than a cached `block.timestamp` across
  `vm.warp`; warps are forward-only; hoist argument-position calls before
  `vm.prank`.
- [x] 7. PARTIAL — `WOOD_TOKEN` + `WOOD_WETH_V2_PAIR` added to chains/4663.json; the deployed oracle address is added at deploy time. Deploy wiring + address-book entries. Note `chains/4663.json` has **no
  `WOOD_TOKEN` key** — add it alongside the pair and oracle addresses.
- [x] 7a. **Deploy pre-flight: assert `woodFallbackPriceX8 != 0` and
  `woodUsdPriceX8 != 0`.** This is what makes the `NoWoodPrice` revert a
  configuration guard rather than a live failure mode; without it the revert is
  reachable in production and the design is worse than what it replaces.
- [x] 8. Gate (serialize forge with `while pgrep -x solc >/dev/null; do sleep 30;
  done` — this machine OOM-kills concurrent `via_ir` builds): `forge build`,
  non-fork `forge test`, `forge fmt --check src test script`, layout goldens.
- [x] 9. Update `docs/robinhood-fork-deployment.md` §10 — it currently frames
  `woodUsdPriceX8` as a fallback to maintain, which is wrong while it is the
  primary. That section should describe the ceiling and what a binding ceiling
  means operationally.
- [x] 10. Open the PR linked to this change. **Independent of all the above:**
  raise `woodHaircutBps` off its 10_000 default as the launch-week mitigation —
  it needs no code and should not wait on this work.
