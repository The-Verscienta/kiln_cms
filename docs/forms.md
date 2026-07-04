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
