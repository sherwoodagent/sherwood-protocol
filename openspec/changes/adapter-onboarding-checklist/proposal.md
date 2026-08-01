# Adapter onboarding checklist: make the dual-gate explicit

## Why

Closes issue #17 (PR #13 re-review, residual 2). An adapter must be BOTH
tier-certified (TierRegistry certify) AND transfer-allowlisted
(`TierRegistry.setAdapterAllowed` / `isAdapterAllowed`, consumed by the
vault's selector guard). The pairing is enforced nowhere on-chain and fails
silently in both directions: forget the allowlist → certified adapter's
legitimate transfers revert; allowlist a generic executor → the selector
guard is bypassed and vault funds can be forwarded anywhere.

## What changes

New docs file `docs/adapter-onboarding-checklist.md` (do NOT touch
`docs/robinhood-fork-deployment.md` — PR #74 just modified it; cross-link
instead):

1. The dual-gate stated up front, with both silent failure directions and
   the exact functions/owners involved (verify current names/signatures
   against `src/TierRegistry.sol` and the vault guard before writing —
   quote real line references).
2. Checklist items: never allowlist a generic/arbitrary-call executor; a
   written answer to "what value-moving selectors can this adapter emit" with
   reviewer sign-off; both gates flipped in the same governance session;
   post-onboarding verification reads (`tierOf`, `isAdapterAllowed`) with
   cast one-liners; the proxied-adapter prohibition from the tier-policy ADR
   (codehash check does not catch impl swaps); de-onboarding order
   (allowlist off BEFORE decert, so the window never has allowlisted+
   uncertified).
3. A "future hardening" note referencing #45 (two-step certify would give
   the checklist a review window) and the CI-invariant idea from the issue
   (flag allowlisted-but-generic targets) as candidate follow-ups, not
   commitments.

## Impact

- One new docs file + a one-line cross-reference from the runbook IF PR #74
  has merged by implementation time (otherwise leave the cross-ref out —
  do not touch a file an open PR owns).
- No code. `forge build` unchanged-tree proof, as in PR #74.
