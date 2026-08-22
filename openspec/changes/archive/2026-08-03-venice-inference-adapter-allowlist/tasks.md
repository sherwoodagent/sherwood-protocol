# Tasks

- [ ] 1. Edit `src/strategies/VeniceInferenceStrategy.sol` in one pass:
  - `ITierBindingPath` interface at file level (mirrors `PortfolioStrategy`'s,
    verbatim: `governor()`, `tierRegistry()`, `isAdapterAllowed(address)`).
  - `error AdapterNotAllowed(address adapter, address registry);`.
  - In `_initialize`: call `_requireAllowedAdapter(p.aeroRouter)` inside the
    existing `if (p.asset != p.vvv)` block, after its existing checks; call
    `_requireAllowedAdapter(p.sVVV)` unconditionally, after the block — both
    before any state write (i.e. before the `asset = p.asset;` assignment
    block begins).
  - Three private view helpers, verbatim from `PortfolioStrategy`:
    `_requireAllowedAdapter`, `_isAdapterAllowed`, `_readAddress`.
- [ ] 2. Build gate: `forge build`.
- [ ] 3. New test file `test/VeniceInferenceStrategyAdapterAllowlist.t.sol`
  covering design.md's 7 scenarios.
- [ ] 4. Targeted run: the new file plus `test/VeniceInferenceStrategy.t.sol`
  (if it exists) — fix any fixture that inits without allowlisting
  `aeroRouter`/`sVVV`.
- [ ] 5. Full gate: `forge build`, non-fork `forge test`, `forge fmt --check
  src/ test/`, `openspec validate venice-inference-adapter-allowlist
  --strict`.
- [ ] 6. Commit, push, open PR against `main`, reference issue #155.
