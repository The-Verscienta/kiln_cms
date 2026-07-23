# Forms

Admin-defined **public forms** (contact, signup, feedback — the Drupal
Webform / WordPress forms workflow): build a form and its typed fields at
`/editor/forms` (admin-only), place it on content with the **form block**,
and review submissions in the same builder.

## Model

- `Form` — name, public `slug`, description, `active` flag, success message,
  optional `notify_email`, submit-button label.
- `FormField` — machine name (the key in each submission), label, type,
  required flag, choice options, help text, placeholder, default value,
  width (full/half/third on a 6-column grid), validation rules, order.
  Types: `string`, `text`, `email`, `phone`, `url`, `integer`, `number`
  (decimal), `date`, `select`, `radio`, `checkboxes` (multi — stored as a
  list), `boolean`, `rating` (1–5), `consent` (when required, must be
  accepted), plus display-only `heading` / `divider` and `hidden` (submits
  its configured value).
  Validation rules (`validation` map, enforced server-side and mirrored as
  HTML attributes): `min_length`/`max_length`, `min`/`max`, `pattern`
  (anchored regex, matched with a ReDoS timeout guard), `message` (custom
  error text).
- `FormSubmission` — the coerced `data` map plus a timestamp. **Privacy-first:
  no IP, no user agent** (rate limiting uses the IP transiently). Admin-only
  to read or delete; deleting a form removes its submissions.

## Conditional logic

A field can be shown only when rules over *earlier* fields match
(`conditions` map: `logic` all/any + rules of `field` / `operator` /
`value`, operators `eq neq contains empty not_empty gt lt`; checkbox
answers treat eq/contains as membership). `/form-conditions.js` (a
standalone script shared by on-site pages and the embed) toggles visibility
and disables hidden inputs; **the server re-evaluates the same rules on
submit** — a hidden field skips `required` and its submitted value is
discarded, so nothing can be smuggled through fields the visitor never saw.
Incomplete rules (blank field, unknown operator) never hide a field.

## Templates

The create flow offers "Blank form" or a built-in template (contact,
feedback, event registration, job application, newsletter signup, quote
request). Templates are JSON files in `priv/form_templates/` — form settings
plus an ordered field list — embedded at compile time by
`KilnCMS.Forms.Templates` and instantiated atomically (a failed field rolls
back the form). To add one, drop a JSON file in that directory and recompile.

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
