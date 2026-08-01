# Forms

Admin-defined **public forms** (contact, signup, feedback — the Drupal
Webform / WordPress forms workflow): build a form and its typed fields at
`/editor/forms` (admin-only), place it on content with the **form block**,
and review submissions in the same builder.

## Model

- `Form` — name, public `slug`, description, `active` flag, success message,
  optional `notify_email`.
- `FormField` — machine name (the key in each submission), label, type
  (`string`, `text`, `email`, `integer`, `boolean`, `date`, `select`),
  required flag, select options, help text, order.
- `FormSubmission` — the coerced `data` map plus a timestamp. **Privacy-first:
  no IP, no user agent** (rate limiting uses the IP transiently). Admin-only
  to read or delete; deleting a form removes its submissions.

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

## Side effects

Each accepted submission optionally mails `notify_email` (Oban `:mail`
queue, HTML-escaped) and fires the `form.submitted` webhook event (selectable
per endpoint at `/editor/webhooks`) with `{form: slug, data: {...}}`.
