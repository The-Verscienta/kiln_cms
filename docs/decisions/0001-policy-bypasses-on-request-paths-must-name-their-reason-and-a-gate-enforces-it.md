# 0001. Policy bypasses on request paths must name their reason, and a gate enforces it

- **Status** — accepted, shipped in
  [0.8.0](../changelog/v0.8.0.md) (Security).
- **References** — [#1309](https://github.com/The-Verscienta/kiln_cms/issues/1309), [#1402](https://github.com/The-Verscienta/kiln_cms/issues/1402).
- **Changelog** — [0.8.0 → Security](../../CHANGELOG.md#080---2026-09-11).

## Decision

**Every policy bypass on a request path now says why it is safe, and a
gate keeps it that way** (#1309). `authorize?: false` skips every Ash policy
on a resource, and it appeared 563 times across `lib/` with no second
reviewer having walked the sites. This pass audits the 47 in
`lib/kiln_cms_web/` (public delivery, previews, webhooks, socket auth,
tenant resolution, tracking, the content editor) plus the four worst
offenders elsewhere (`Firing.References`, `Billing`, `Newsletter.TierSync`,
`Automation.RuleWorker`): two `RedirectLive` reads now run as the acting
admin instead of bypassing; every other site keeps the bypass with a comment
naming the reason (a delivery action whose own filter carries the
published/audience/unlock grant, a tenant already scoped, a pre-auth flow
with no actor, a system read of display data on a self-only-read resource).
New `mix kiln.authz.check` — in `mix precommit` and CI — fails on a new
`authorize?: false` under `lib/kiln_cms_web/` without such a comment within
12 lines of the call — one comment per call, so a second bypass pasted under
a justified one is red (AST-based, so the phrase in a string or doc is not a
site). The
audit also found three tenant-less reads on org-scoped resources that would
be refused under the strict (production) tenancy build: content preview
tokens now carry the record's `org_id` (`KilnCMS.CMS.PreviewToken`; a token
minted without one is `:invalid`, and one presented on another site's host
is refused, as release previews already were), and the dynamic-type name lookups in
`Firing.References` and `BustContentCache` pass the record's tenant.
Non-web code is not gated yet; a system actor (#1402) is the way to move
worker code under the policies rather than around them.
