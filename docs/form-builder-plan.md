# Form Builder Redesign Plan

> **Status: COMPLETE.** All six phases shipped on PR #447 (2026-07-23/24).
> `docs/forms.md` is the living documentation; this plan is kept as the
> design record.

Goal: evolve Kiln's form editor from the current flat "add a field row" admin page into a
visual form builder modeled on **WPForms** and **Formidable Forms** — the two strongest
form-builder UX references in the WordPress ecosystem.

This is a plan for the *editor and form model*; the public submission pipeline
(honeypot, rate limit, coercion/validation, Oban notification, webhook) stays as-is
underneath and is extended, not replaced.

## What "based on WPForms / Formidable" means

Both products share the same core builder model, which is what we adopt:

1. **Full-screen builder** per form (not a section of a list page): field palette on one
   side, a **live preview canvas** of the actual form in the middle, and a field
   **options panel** that opens when you click a field on the canvas.
2. **Add by drag or click** from a categorized palette (Standard / Advanced fields).
3. **Click-to-edit** every field inline — no delete-and-re-add.
4. **Drag to reorder** (and drag between columns for layout).
5. **Tabbed form settings**: General, Notifications, Confirmations (WPForms's top-level
   nav: Setup → Fields → Settings).
6. **Templates** on form creation ("start from scratch" or a preset).
7. **Conditional logic** per field (show/hide when rules match).
8. **Multi-page forms** via a page-break field with a progress indicator.

Deliberately **not** copied (out of scope, at least initially): payments, file uploads
(anonymous-upload risk — existing design decision in `form_field.ex`), third-party
CAPTCHA (honeypot + rate limit already in place; optional Turnstile could come later),
marketing/CRM integrations (webhooks already cover this), Formidable "Views"
(frontend display of entries), conversational forms, save-and-resume.

## Current state (baseline)

- `KilnCMS.CMS.Form` (`lib/kiln_cms/cms/form.ex`): name, slug, description, active,
  success_message, notify_email; org-scoped; `active_by_slug` public read.
- `KilnCMS.CMS.FormField` (`lib/kiln_cms/cms/form_field.ex`): 7 types
  (`string, text, email, integer, boolean, date, select`), name/label/required/options/
  help_text/position. `position` exists but the editor never sets it.
- `KilnCMS.CMS.FormSubmission`: privacy-first (no IP/UA), last-100 view in admin.
- Editor `KilnCMSWeb.FormLive` (`/editor/forms`): single page — list + settings +
  flat add-field row + recent submissions. No reorder, no inline edit, no preview,
  no logic, no pages, no templates.
- Public render: `BlockComponents.public_form/1`, used on-site (`:form` block) and by
  the iframe embed (`/forms/:slug/embed` + `embed.js` auto-resize).
- A `Sortable` Phoenix hook already exists in `assets/js/app.js` (block editor); reuse it.

## Phase 1 — Builder UX core (the big win)

New route `live "/editor/forms/:id"` → `FormBuilderLive`; `/editor/forms` stays as the
list + create page (create gains a template picker in Phase 3).

Layout (Layouts.console, full-width working area):

```
┌────────────┬──────────────────────────┬────────────────┐
│ Palette    │ Canvas (live preview of  │ Field options  │
│ (grouped   │ public_form markup, each │ (selected      │
│  field     │ field wrapped in a       │  field's       │
│  types)    │ click-target + drag      │  settings) or  │
│            │ handle)                  │ form settings  │
└────────────┴──────────────────────────┴────────────────┘
```

- **Canvas** reuses `public_form/1` rendering in a "builder mode" (inputs disabled,
  each field wrapped with selection ring, drag handle, duplicate + delete buttons) so
  the preview is the real markup — WYSIWYG for free, no drift between builder and
  public form.
- **Palette**: click appends, drag inserts at position. Reuse the `Sortable` hook for
  reorder; persist `position` (finally) via a `reorder` action that renumbers.
- **Options panel** (replaces delete-and-re-add): label, machine name (auto-generated
  from label, editable while the field has no submissions), required, help text,
  placeholder, default value, options list for choice fields, width. Mirrors WPForms's
  General/Advanced tabs; conditional logic tab arrives in Phase 4.
- **Form settings** move into tabs on the same screen: General (name, slug,
  description, active, submit button label), Notifications, Confirmations,
  Embed (the existing snippet).
- **Duplicate field** and **duplicate form** actions (both products have them; cheap).

Resource work: `FormField.update` becomes editable from the UI; add `reorder` +
`duplicate` actions; add `placeholder`, `default_value`, `width` attributes.

## Phase 2 — Field taxonomy expansion

Grow from 7 types toward the WPForms "Standard fields" set, keeping the
no-anonymous-uploads rule:

| Group    | New types |
|----------|-----------|
| Standard | `radio` (single choice, rendered as radios), `checkboxes` (multi-select), `phone`, `url`, `number` (decimal; `integer` stays), `hidden` |
| Layout   | `heading`/`html` content block, `divider`, `page_break` (Phase 5) |
| Special  | `name` (composite first/last optional), `rating` (1–5), `consent` (GDPR checkbox with required-true semantics, links to policy) |

Per-field validation config (WPForms "Advanced" tab): min/max length, min/max value,
pattern (server-side anchored regex with a re-timeout guard), custom error message.
All enforced in `KilnCMS.Forms.submit/3` coercion and mirrored as HTML attributes
client-side.

Multi-value answers mean `FormSubmission.data` values can be lists — the notification
email table and submissions view must render lists.

## Phase 3 — Templates

- Template = JSON seed (form settings + field list) in `priv/form_templates/*.json`;
  a behaviour-free registry module lists them (contact, feedback, event registration,
  job application, newsletter signup, quote request — ~6 to start).
- Create flow becomes: "Blank form" or a template card grid (both products lead with
  this screen — WPForms "Setup" step).
- Plugin seam later: `Kiln.Plugin` can contribute templates.

## Phase 4 — Conditional logic

- `FormField.conditions` embedded attribute:
  `%{logic: :all | :any, rules: [%{field: name, operator: op, value: v}]}` with
  operators `eq, neq, contains, empty, not_empty, gt, lt` (Formidable's core set).
- Editor: "Smart Logic" section in the options panel (WPForms naming) — rule rows with
  field/operator/value selects, restricted to fields *above* the target (no cycles).
- Public render: a small JS hook evaluates rules on input and toggles visibility.
- **Server is the authority**: `Forms.submit/3` re-evaluates conditions against the
  submitted data; hidden fields skip `required` validation and their values are
  discarded (prevents smuggling data through hidden fields).
- Conditional **confirmations** and **notifications** (both products): per-rule
  success message / notify address, evaluated server-side only. *(Deferred to
  phase 6, where confirmations/notifications are reworked anyway.)*

## Phase 5 — Multi-page forms

- WPForms model: `page_break` layout field splits the field list into pages; a
  progress bar (steps or percentage, configurable) renders on top.
- Public render: all pages in the DOM, one visible; Previous/Next buttons; per-page
  client validation before advancing; single POST at the end (no partial-submission
  storage — keeps the privacy-first submission model).
- Embed height auto-resize already handles page switches via `embed-frame.js`.

## Phase 6 — Confirmations & notifications parity

- `Form.confirmation_type`: `:message` (today's success_message) | `:redirect`
  (`redirect_url`, same-origin or absolute allowed, validated).
- **Autoresponder** (both products ship this): optional confirmation email to the
  submitter — enabled only when the form has an `email` field; subject/body templates
  with `{{field_name}}` interpolation (HTML-escaped); sent through the existing
  `NotificationWorker` path on the `:mail` queue.
- Multiple admin notification recipients (comma-separated), per-notification
  conditional rules (Phase 4 machinery).
- Submissions UX: per-submission detail view, CSV export (stream, admin-only —
  mirrors the governance CSV export), simple count-per-day sparkline. Full analytics
  (views/conversions/drop-off) is out of scope.

## Data-model summary

- `FormField` gains: `placeholder`, `default_value`, `width` (`:full/:half/:third`),
  `validation` (map), `conditions` (map), expanded `field_type` enum. All additive,
  nullable → no destructive migration; existing forms unaffected.
- `Form` gains: `submit_label`, `confirmation_type`, `redirect_url`, autoresponder
  fields (`autoresponder_enabled/subject/body`), `progress_indicator`.
- `GET /forms/:slug` JSON schema endpoint grows the new metadata (headless consumers
  can implement the same logic client-side); additive, non-breaking.

## Sequencing note

Phases 1–2 are the visible transformation and stand alone. 3 is cheap after 1.
4–6 are independent of each other after 2. Each phase is one PR-sized unit with the
usual gate (format / credo --strict / sobelow / dialyzer, `mix precommit`).
