# 0006. A form's embed allowlist belongs to the form, not to the deployment

- **Status** — accepted, shipped in
  [0.5.0](../changelog/v0.5.0.md) (Security).
- **References** — [#648](https://github.com/The-Verscienta/kiln_cms/issues/648), [#562](https://github.com/The-Verscienta/kiln_cms/issues/562).
- **Changelog** — [0.5.0 → Security](../../CHANGELOG.md#050---2026-08-09).

## Decision

**A form's embed allowlist is now the form's, not the deployment's** (#648).
`EMBED_ORIGINS` has no tenant dimension, so on a multi-org instance it had to
be the *union* of every org's embedders — and that union was what every org's
forms became framable by. An operator allowlisting `https://partner-a.com` for
one site also authorised it to frame every other site's forms, which is the
overlay-and-harvest attack #562 closed, one tenant boundary over. The builder's
Embed tab could not be accurate either: it answered a deployment-wide question,
so an admin checking "may my embedders frame this?" before pasting a snippet
got an approximation of the answer.

Forms carry an `embed_origins` allowlist, set in the Embed tab, and the embed
page's `frame-ancestors` comes from it. Three states: **use the deployment
default** (unset — unchanged behaviour, and the whole single-org story),
**this site only** (closed for this form whatever the deployment allows), and
**only these sites**. A form's list *replaces* the deployment's rather than
extending it, so an org can also narrow below what another org needed added
globally. The tab's banner and allowlist line now read the policy that will
actually be served for that form, read back out of the rendered directive so
they cannot name an origin the header does not grant.

Entries are validated on save with the same predicate as the per-site CSP
additions in Code Injection (`KilnCMS.CMS.Validations.CspOrigins`): a full
origin, no keyword sources, no bare `*`, and nothing that could end the
directive or the header. A bad entry is **refused, naming itself**, rather
than dropped — a shorter allowlist than the admin typed is indistinguishable
from a deliberate one. `EMBED_ORIGINS` keeps its own looser grammar and its
fail-closed parsing; nothing about a single-org deployment changes.

**On a multi-org deployment, set the allowlist per form and leave
`EMBED_ORIGINS` unset** — a form that has not been given one still inherits
the deployment's, so the shared union governs every untouched form exactly as
before. `docs/threat-model.md` records what that leaves open.
