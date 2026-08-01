# Tasks

- [x] 1. ~~Verify the fork before building anything.~~ **DONE 2026-08-01 —
  proven standard by CREATE2 derivation** (see design.md risks). The pair at
  `0xBF3BB81de6285b8310A028d1C2Cd38F9419d54C1` reproduces exactly from the
  canonical Uniswap V2 init-code hash under factory
  `0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f`, so `_update`, the UQ112x112
  cumulatives and the 2^32 timestamp wrap are all standard. No deviation; the
  change rests on solid ground. **Re-run this derivation if the pair address
  ever changes** — it is a one-command check.
- [ ] 2. Re-read the live reserves and ETH/USD answer; update design.md's
  measured block if they have moved materially.
- [ ] 3. `src/pricing/WoodTwapOracle.sol`: permissionless `update()` storing
  `(cumulative, timestamp)`; `view consult()` returning
  `(uint256 twapUsdX8, bool ok)`; window + `maxTwapAge` bounded setters; USD
  conversion via the ETH/USD feed with the same staleness treatment used
  elsewhere in the ledger.
- [ ] 4. `src/ExposureLedger.sol`: apply the ceiling in `_woodPrice`
  (`min(governance, twap)` then `_haircut`), wire/unwire setter with the
  `code.length` + `try/catch` protection `_woodPrice` already uses for feeds,
  and extend `woodPriceDetail()` per the spec delta.
- [ ] 5. Interfaces + layout goldens (`./script/check-layout-goldens.sh`),
  since `ExposureLedger` gains storage.
- [ ] 6. Tests — failing-first where feasible, one per spec scenario. Include:
  ceiling binds only downward; stale snapshot degrades rather than reverts;
  codeless/reverting oracle degrades; ETH/USD stale degrades; permissionless
  `update()`; window bounds rejected; unwire works. Repo gotchas: use
  `vm.getBlockTimestamp()` rather than a cached `block.timestamp` across
  `vm.warp`; warps are forward-only; hoist argument-position calls before
  `vm.prank`.
- [ ] 7. Deploy wiring + address-book entries. Note `chains/4663.json` has **no
  `WOOD_TOKEN` key** — add it alongside the pair and oracle addresses.
- [ ] 8. Gate (serialize forge with `while pgrep -x solc >/dev/null; do sleep 30;
  done` — this machine OOM-kills concurrent `via_ir` builds): `forge build`,
  non-fork `forge test`, `forge fmt --check src test script`, layout goldens.
- [ ] 9. Update `docs/robinhood-fork-deployment.md` §10 — it currently frames
  `woodUsdPriceX8` as a fallback to maintain, which is wrong while it is the
  primary. That section should describe the ceiling and what a binding ceiling
  means operationally.
- [ ] 10. Open the PR linked to this change. **Independent of all the above:**
  raise `woodHaircutBps` off its 10_000 default as the launch-week mitigation —
  it needs no code and should not wait on this work.
