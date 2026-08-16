# Forms

Admin-defined **public forms** (contact, signup, feedback — the Drupal
Webform / WordPress forms workflow): build a form and its typed fields at
`/editor/forms` (admin-only), place it on content with the **form block**,
and review submissions in the same builder.

## Model

- `Form` — name, public `slug`, description, `active` flag, success message,
  optional `notify_email`, optional submitter autoresponder (subject/body +
  on/off toggle — see Side effects below).
- `FormField` — machine name (the key in each submission), label, type
  (`string`, `text`, `email`, `integer`, `boolean`, `date`, `select`),
  required flag, select options, help text, order.
- `FormSubmission` — the coerced `data` map, a moderation `status`
  (`new`/`reviewed`/`spam`) and `spam_score`, plus a timestamp.
  **Privacy-first: no IP, no user agent** (rate limiting uses the IP
  transiently). Admin-only to read, moderate, or delete; deleting a form
  removes its submissions.
- `FormSpamSettings` — one row per org, a disallowed-keyword list for the
  spam scorer below. Admin-only, never delivered.
- `SiteEmbedSettings` — one row per org, this org's default `frame-ancestors`
  allowlist for forms that set none of their own (below). Admin-only, never
  delivered — same shape as `FormSpamSettings`, edited through the generic
  Ash Admin resource UI rather than a page of its own.

## Rendering

The `:form` content block references a form by slug:

- **On-site** pages render the live form server-side (inputs per field, a
  visually-hidden honeypot) POSTing to `/forms/<slug>`; a successful
  submission shows the form's success message. An inactive form renders
  nothing (form and field edits clear the delivery cache immediately).
- **Fired `:web` artifacts** carry `<div data-kiln-form="<slug>"></div>` —
  headless frontends fetch the schema from `GET /api/forms/<slug>` (fields,
  labels, types, options, honeypot field name, submit URL) and POST JSON to
  `/api/forms/<slug>` (`{ok: true}` or `{ok: false, errors: {...}}`).

## Embedding on another site

The builder's **Embed** tab hands out a one-line snippet
(`<script src=".../embed.js" data-kiln-form="<slug>">`) that drops a
self-sizing iframe of `GET /forms/<slug>/embed` onto a third-party page.

That route serves its own CSP, because the site-wide `frame-ancestors 'self'`
would block the iframe. Which parents may frame it is set **on the form**, in
the Embed tab's *Who may embed this form* control, falling back through this
org's own default (`SiteEmbedSettings`, #1131) and then the deployment-wide
`EMBED_ORIGINS` for forms that leave it alone (see
[`KilnCMSWeb.Embed`](../lib/kiln_cms_web/embed.ex) and
[`KilnCMS.Forms.EmbedPolicy`](../lib/kiln_cms/forms/embed_policy.ex)):

| Embed tab | `frame-ancestors` | Effect |
| --- | --- | --- |
| **Use this site's default** (unset — the default) | this org's `SiteEmbedSettings`, or `EMBED_ORIGINS` if this org has set none | The multi-org setup: one setting per org, every form in it. |
| **This site only** | `'self'` | Cross-site embedding off for this form, whatever the org or the deployment allows. |
| **Only these sites** | `'self' https://acme.com https://blog.acme.com` | This form's own allowlist, **instead of** the org's or the deployment's. `'self'` is always kept, so allowlisting a partner never removes same-origin framing. |

An org's own default (`SiteEmbedSettings`, admin-only) works the same way one
rung up: unset inherits `EMBED_ORIGINS`, `[]` closes every form in the org
that has none of its own, and a list replaces the deployment's for the org.

And the deployment default itself, for an org that has set no default of its
own:

| `EMBED_ORIGINS` | `frame-ancestors` | Effect |
| --- | --- | --- |
| unset or blank (**default**) | `'self'` | Cross-site embedding off. The snippet still works on pages served from the form's *own* origin. |
| `https://acme.com,https://blog.acme.com` | `'self' https://acme.com https://blog.acme.com` | The intended production setting for a single-org deployment. |
| `*` | `*` | Any site may frame the form. |

**The operator can make it a ceiling** (#1133). Set `EMBED_ORIGINS_LOCKED=true`
and `EMBED_ORIGINS` is the *most* any form or org in the deployment may open
as well as the default: a form's or org's own list may narrow it (a subset,
or "This site only") but every entry must be covered by it — same scheme,
same port, the same host or a subdomain of a `*.`-wildcarded one. An admin
who saves an entry outside it is refused, with the message naming the
refused entry and *not* the ceiling (which on a shared deployment would list
every other org's partners), and told to ask the operator. Lists saved
before the cap was turned on are clamped to it when served, so turning it
on takes effect immediately without a data fix. The Embed tab says a cap
exists when one does. With the cap off — the default — nothing above
changes; `EMBED_ORIGINS=*` under the cap is a ceiling of everything, and an
unset `EMBED_ORIGINS` under the cap closes framing deployment-wide whatever
a tenant writes.

**The default is closed** (#562). Copying the snippet onto an external site
before allowing that site renders a blank iframe and a CSP violation in that
site's console — the builder's Embed tab says so, and also shows the origins
that will actually be served for *that* form, so you can check a host before
pasting the snippet there.

**Your own logs will tell you too** (#650). A browser framing the embed page
sends Fetch Metadata (`Sec-Fetch-Dest: iframe` with a `Sec-Fetch-Site` that is
not `same-origin`), so when that arrives and the form's policy is closed the CMS
logs a warning naming the parent origin — and naming *which* of the settings
closed it, so you edit the one actually in force rather than the one you happen
to know about. At most once an hour per node, so a busy embed route cannot flood
the log. Note a sibling subdomain counts as blocked: `frame-ancestors 'self'`
matches the *origin*, so `https://blog.acme.com` framing `https://acme.com`'s
CMS needs an allowlist entry like any unrelated host.

(The warning still only ever names "this form's own" or `EMBED_ORIGINS` — an
org default of `[]` that closed the form reads as "this form's own" in the
message, a known imprecision documented on `KilnCMS.Forms.EmbedPolicy`. The
*policy* served is always correct; only this log line's wording can point at
the wrong one of the two commoner settings.)

The warning fires only while the policy allows **nobody**. A *partial* list —
one parent allowed, another forgotten — leaves the forgotten parent just as
blocked, and silent: the CMS cannot tell an omission from a deliberate refusal.
Check the list the form's Embed tab shows you.

Why not leave it open? The embed page carries no ambient credentials — it is an
anonymous public form, and a cross-site iframe never receives the `SameSite=Lax`
session cookie — so there is no session to steal. But framing is itself the
attack: any site could overlay the form invisibly and harvest into *your*
submissions table under *your* org's branding, and submission is deliberately
CSRF-free (see below), so nothing else stands behind it.

A malformed `EMBED_ORIGINS` **closes** the policy rather than widening it: every
entry must look like a CSP host source, and one bad entry discards the whole
list for `'self'` (with a warning on stderr) instead of applying the rest. Two
shapes this catches — a `*` mixed into a list, which would otherwise render
`frame-ancestors * https://acme.com` and grant every site while looking like an
allowlist; and an entry containing `;`, which would append further directives to
the header, since `frame-ancestors` is the last one emitted. Write
`EMBED_ORIGINS=*` on its own if you mean "any site".

A form's own list is stricter still, because it comes from a settings form
rather than from the operator's shell: each entry must be a **full origin**
(`https://acme.com`, optionally `*.`-prefixed on the leftmost label, optionally
with a port — `http://` only for `localhost`), and a bad entry is **refused at
save**, naming itself, rather than silently dropped. Same predicate as the
per-site CSP additions in Code Injection
(`KilnCMS.CMS.Validations.CspOrigins`).

**Per form, because forms are org-scoped** (#648). `'self'` is the *form's*
origin — on a multi-org instance each org resolves to its own `custom_domain` or
`<slug>.<base_host>` (see `KilnCMSWeb.Tenant`), so one org's page framing
another org's form is cross-site and needs an allowlist entry. `EMBED_ORIGINS`
has no tenant dimension, so as a deployment-wide allowlist it has to be the
*union* of every org's embedders — and that union is what every org's forms
would become framable by, which is the overlay-and-harvest attack above one
tenant boundary over. Set the allowlist on the form (or, for a whole org at
once, on `SiteEmbedSettings`) instead and each org authorises only its own
embedders; a form's list replaces the org's and the deployment's rather than
extending them, so a form — or an org — can narrow below what someone else
needed added globally.

Who owns the setting follows the risk: `frame-ancestors` on this page governs
who may overlay *this org's* form and harvest into *this org's* submissions, so
an org admin sets it, at either grain. It grants nothing across the tenant
boundary — framing org B's embed page conveys no access to org A. There is no
operator ceiling over it for the same reason: an org admin may open framing on
their own forms, or their own org's default, that `EMBED_ORIGINS` leaves
closed (see #1133 for the residual this leaves for a hosted deployment).

**On a multi-org deployment, set an org default (`SiteEmbedSettings`) rather
than `EMBED_ORIGINS`.** One setting per org reaches every form in it that
hasn't been given its own list, without touching another org's; leave
`EMBED_ORIGINS` unset the way #648 already recommended. A form (or an org)
that has been given no default of its own still inherits the next rung
up — for an org with no default configured, that is still the deployment's
shared union exactly as before #1131, so an org that wants isolation has to
actually set its own default, not merely rely on nobody else changing
`EMBED_ORIGINS`.

**Revoking an origin takes up to a minute to reach everyone.** The embed page is
served `Cache-Control: public, max-age=60`, so a shared cache or a browser that
fetched it in the preceding minute can keep replaying the older, more permissive
policy after you narrow the list. There is no purge to issue; wait a minute
before treating a revocation as in force.

## Abuse protection

No CSRF on the submission endpoints (they're anonymous, and fired artifacts
couldn't carry a token). Instead:

- **honeypot** — a hidden `website` input; a filled honeypot gets a *fake
  success* and stores nothing;
- **rate limit** — the tight per-IP `form` bucket (20/min);
- server-side validation of every declared field (unknown keys dropped).

## Spam moderation (#477)

Post-storage triage on top of the pre-storage defenses above: every accepted
submission is scored by the `Kiln.Forms.SpamCheck` registry (the
`Kiln.Advisory` shape, adapted to a weighted score instead of a
severity-tiered finding — see the module docs for the plugin contract).
Shipped core checks:

| Check | Signal | Weight |
| --- | --- | --- |
| `LinkDensity` | 3+ links in the free-text fields | 40 |
| `DisallowedKeywords` | matches the org's own keyword list (`FormSpamSettings`, `/editor/forms` has no UI for it yet — manage it via `/admin`) | 50 |
| `FillTime` | submitted in under 1.5s of the form rendering (a signed, unforgeable "now" token rides in a hidden field) | 30 |
| `LocaleMismatch` | predominantly non-Latin script against a Latin-script declared locale | 35 |

Weights sum; a submission at or past `Kiln.Forms.SpamCheck.threshold/0`
(default 50) is stored `:spam` — never a hard reject, since the score can be
wrong and the row is still worth an admin's eyes. A `:spam` submission never
reaches the autoresponder or the `form.submitted` webhook (see Side effects
below); everything else about it — CSV export inclusion, retention — is an
admin decision, not automatic.

The builder's **Entries** tab filters by status, marks a submission
spam/reviewed individually or in bulk, and exports a CSV
(`/editor/forms/:id/entries/export.csv`, admin-gated, `?status=` filterable).
`:spam` rows are pruned after `spam_retention_days` (config, default 30) by a
nightly job; `:new`/`:reviewed` rows are kept indefinitely, same as before
this feature.

A third-party provider (Akismet-style) plugs in as a `Kiln.Forms.SpamCheck`
module, declared from the plugin's `spam_checks/0` callback — see
`Kiln.Plugin`.

## Side effects

Each accepted submission that wasn't scored `:spam` optionally mails
`notify_email` (Oban `:mail` queue, HTML-escaped), optionally autoresponds to
the submitter (below), and fires the `form.submitted` webhook event
(selectable per endpoint at `/editor/webhooks`) with `{form: slug, data: {...}}`.

### Autoresponder (#468)

The builder's **Confirmations** tab can turn on a confirmation email back to
the *submitter* — separate from `notify_email`, which mails the admin.
It only ever fires when the form declares an `:email` field *and* the
submission filled it in (`KilnCMS.Forms.Autoresponder.eligible?/3` is the one
place that decides this, so the send path and the config-time validation
below can't drift on it); a `:spam`-scored submission is excluded the same as
`notify_email` and the webhook.

Subject and body are `Kiln.Tokens` patterns using the same `[token]` bracket
syntax as slug/alias patterns (`KilnCMS.Slug.Pattern`), not `{{field}}`
mustache — one substitution syntax across the app. Available tokens are every
declared field as `[field:<name>]`, plus `[form-name]`; the tab lists them
live as a hint. The body is HTML (values are escaped); the subject is a mail
header (values are not — HTML in a subject would just show as literal tags).
Saving with the toggle on requires a non-blank subject and body, both
referencing only tokens the form currently has; saving with it off skips both
checks, so a draft template — even one written against a field you haven't
added yet — never blocks an unrelated save.
