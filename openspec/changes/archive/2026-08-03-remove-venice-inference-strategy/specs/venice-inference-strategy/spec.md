# venice-inference-strategy (delta)

The capability is retired whole: `VeniceInferenceStrategy` is deleted from the
repo outright (Ana's direct instruction, not tied to an issue). The one
requirement this spec defines — allowlisting `aeroRouter`/`sVVV` through the
tier registry at init — only exists to protect `VeniceInferenceStrategy`'s own
`_initialize`; with the contract gone, the requirement has no subject left to
constrain.

At sync/archive time this spec ends up with zero requirements: delete
`openspec/specs/venice-inference-strategy/spec.md` entirely rather than
leaving an empty shell (same convention as `retire-lane-a`'s treatment of
`instant-exit-fees`). No successor strategy reintroduces this capability —
`PortfolioStrategy`'s own adapter-allowlist requirement lives in its own spec
capability, unaffected by this change.

## REMOVED Requirements

### Requirement: aeroRouter and sVVV must be allowlisted in the vault's tier registry

**Reason**: `VeniceInferenceStrategy` — the only contract this requirement
constrains — is deleted from the repo. The requirement was never general
(it names `VeniceInferenceStrategy._initialize`, `aeroRouter`, `sVVV`
specifically); there is no successor surface to migrate it to.
**Migration**: None. No vault or governor storage encodes this check, and no
strategy clone of this template can exist post-deletion (the template itself
is gone, so `Clones.clone(template)` has nothing to clone).
