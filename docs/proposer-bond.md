# Proposer bond (propose path)

This is the propose-path WOOD bond, **not** the SHE-126 fee split.

At `propose`, `SyndicateGovernor` pulls WOOD into `ProposerBondEscrow` via
`lockBond`. Amount:

`ExposureLedger.proposerBondWood(asset, requiredCoverage)`
= `coverageUsd(asset, requiredCoverage) * proposerBondBps / 10_000` converted
at `woodPriceX8()`. Default `proposerBondBps` = 100 (1%). Tier-2 uncertified
coverage is full notional. **The bond scales — do not treat a fixed WOOD figure
as the requirement.** Example only: ~230 WOOD for a 100 USDG book on the
Robinhood mainnet fork at a then-current price.

This is a **second** WOOD pull after the 10,000 WOOD owner stake
(`prepareOwnerStake`). The CLI should quote the view, set escrow allowance, and
exit with `InsufficientProposerBondWood` if `balanceOf(proposer) < bond`. Fork
faucet 15k WOOD covers the owner stake plus a small-book bond.
