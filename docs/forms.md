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
would block the iframe. Which parents may frame it comes from **`EMBED_ORIGINS`**
(see [`KilnCMSWeb.Embed`](../lib/kiln_cms_web/embed.ex)):

| `EMBED_ORIGINS` | `frame-ancestors` | Effect |
| --- | --- | --- |
| unset or blank (**default**) | `'self'` | Cross-site embedding off. The snippet still works on pages served from the form's *own* origin. |
| `https://acme.com,https://blog.acme.com` | `'self' https://acme.com https://blog.acme.com` | The intended production setting. `'self'` is always kept, so allowlisting a partner never removes same-origin framing. |
| `*` | `*` | Any site may frame the form. |

**The default is closed** (#562). Copying the snippet onto an external site
before setting `EMBED_ORIGINS` renders a blank iframe and a CSP violation in
that site's console — the builder's Embed tab says so, and also shows the
current allowlist so you can check a host before pasting the snippet there.

**Your own logs will tell you too** (#650). A browser framing the embed page
sends Fetch Metadata (`Sec-Fetch-Dest: iframe` with a `Sec-Fetch-Site` that is
not `same-origin`), so when that arrives and `EMBED_ORIGINS` is unset the CMS
logs a warning naming the variable and the parent origin. Once per node, so a
busy embed route cannot flood the log — restart to see it again. Note a sibling
subdomain counts as blocked: `frame-ancestors 'self'` matches the *origin*, so
`https://blog.acme.com` framing `https://acme.com`'s CMS needs an allowlist
entry like any unrelated host.

Why not leave it open? The embed page carries no ambient credentials — it is an
anonymous public form, and a cross-site iframe never receives the `SameSite=Lax`
session cookie — so there is no session to steal. But framing is itself the
attack: any site could overlay the form invisibly and harvest into *your*
submissions table under *your* org's branding, and submission is deliberately
CSRF-free (see below), so nothing else stands behind it.

A malformed value **closes** the policy rather than widening it: every entry
must look like a CSP host source, and one bad entry discards the whole list for
`'self'` (with a warning on stderr) instead of applying the rest. Two shapes
this catches — a `*` mixed into a list, which would otherwise render
`frame-ancestors * https://acme.com` and grant every site while looking like an
allowlist; and an entry containing `;`, which would append further directives to
the header, since `frame-ancestors` is the last one emitted. Write
`EMBED_ORIGINS=*` on its own if you mean "any site".

**Origins are per deployment, not per org.** `'self'` is the *form's* origin —
on a multi-org instance each org resolves to its own `custom_domain` or
`<slug>.<base_host>` (see `KilnCMSWeb.Tenant`), so one org's page framing
another org's form is cross-site and needs an allowlist entry. The allowlist
itself is global, so it must be the union of every org's embedders, and that
union is what every org's forms become framable by. Tracked in #648.

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
