# Forms

Admin-defined **public forms** (contact, signup, feedback — the Drupal
Webform / WordPress forms workflow): build a form and its typed fields at
`/editor/forms` (admin-only), place it on content with the **form block**,
and review submissions in the same builder.

## Model

- `Form` — name, public `slug`, description, `active` flag, success message,
  optional `notify_email`, optional submitter autoresponder (subject/body +
  on/off toggle — see Side effects below), and `challenge` (`:off`, the
  default, or `:always`), whether visitors must complete a human-verification
  check (#2249, see [Abuse protection](#abuse-protection)).
- `FormField` — machine name (the key in each submission), label, type
  (see [Field types](#field-types)), required flag, options (`select`,
  `radio`, `checkboxes`), `min_value` / `max_value` / `step` (`number`,
  `rating`), help text, order, and an optional `condition` that shows or
  hides the field based on earlier answers (#2262, see
  [Show or hide a field based on an earlier answer](#show-or-hide-a-field-based-on-an-earlier-answer)).
- `FormSubmission` — the coerced `data` map, a moderation `status`
  (`new`/`reviewed`/`spam`) and `spam_score`, what the human-verification
  check decided (`challenge`: `passed`, `missing`, `wrong_host`,
  `unavailable`, or empty when the form asked for none), plus a timestamp.
  **Privacy-first: no IP, no user agent** (rate limiting uses the IP
  transiently). Admin-only to read, moderate, or delete; deleting a form
  removes its submissions.
- `FormSpamSettings` — one row per org, a disallowed-keyword list for the
  spam scorer below. Admin-only, never delivered.
- `SiteEmbedSettings` — one row per org, this org's default `frame-ancestors`
  allowlist for forms that set none of their own (below). Admin-only, never
  delivered — same shape as `FormSpamSettings`.

Both are edited on **`/editor/forms/settings`** (`KilnCMSWeb.FormSettingsLive`,
#1232), linked from the Forms page. They used to be reachable only through the
generic Ash Admin resource UI, which `config/prod.exs` compiles out — so on a
production deployment neither had any in-product UI at all.

## Field types

Every value is validated server-side whatever the client did, on the on-site
form, the embed and `POST /api/forms/<slug>` alike. Blank optional values are
dropped (nothing stored). A list or object sent for a single-value type is
refused as "is not valid".

| Type | Accepts | Stored in `data` (and in the `form.submitted` webhook) |
| --- | --- | --- |
| `string`, `text` | any text, trimmed | string |
| `email` | an email address | string |
| `integer` | a whole number | integer |
| `number` | a decimal number, within `min_value`/`max_value`, on a `step` grid (counted from `min_value`, else 0) when set. `+5` and `-0` pass; `.5`, `5.`, `1_000`, `1e3`, `nan`, `inf` and over-long strings do not | integer when whole (`1.0` is stored as `1`), otherwise a float |
| `rating` | a whole number from 1 to `max_value` (1 to 10, default 5); `"3"` or `3`, never `3.5`. Changing `max_value` later does not re-check stored answers | integer |
| `boolean` | a checkbox | boolean |
| `date` | an ISO 8601 date | string |
| `select`, `radio` | exactly one of the field's `options` | string |
| `checkboxes` | any of the field's `options`: a JSON array, repeated `name[]` pairs, or one string. Duplicates collapse and the order follows `options`. Required means at least one; `[]` and `[""]` count as blank | list of strings |
| `phone` | digits with `+ ( ) - .` and spaces; 6 to 15 digits, at most 32 characters. Stored as typed, not normalised | string |
| `url` | an `http` or `https` URL with a host, no credentials (`http://a@b` is refused), at most 2048 bytes. `javascript:` and `data:` are refused | string |
| `hidden` | free text, trimmed | string |

In the builder's **Add a field** palette the types are labeled **Single line
text** (`string`), **Paragraph text** (`text`), **Email**, **Number**
(`integer`), **Checkbox** (`boolean`), **Date**, **Dropdown** (`select`),
**Radio buttons** (`radio`), **Checkbox group** (`checkboxes`), **Phone**,
**Web address** (`url`), **Number (range)** (`number`), **Rating** and
**Hidden field** (`hidden`).

Things to know:

- **`hidden` is submitter-controlled.** It is a plain input the visitor (or a
  script) can change; the server does not require it to equal `default_value`.
  Use it for tracking hints such as UTM parameters, never for anything you
  would trust (a price, a role, an id). A hidden field cannot be `required`.
- **Webhook and export shapes.** `form.submitted` `data` can now hold lists
  (`checkboxes`) and numbers (`number`, `rating`, `integer`) as well as
  strings and booleans: receivers that assumed every value is a string need
  updating. The entries CSV joins a list with `, `, and its existing formula
  guard prefixes a cell starting with `=`, `+`, `-` or `@` with `'`, so a phone
  number such as `+1 555 0100` or an option beginning with `=` exports as
  `'+1 555 0100`. Notification emails, the autoresponder and the Entries tab
  show a list as `a, b`.
- **Unknown future types.** The set of types grows additively. A client that
  renders the schema should fall back to a plain text input for a `type` it
  does not know.
- **Upgrade: do not use the new types until every node runs this release.**
  A node on the previous release cannot load a form field whose type it does
  not know, so the public form fails to load there. Rolling back to the
  previous release likewise breaks every form that uses a new type (remove
  those fields first). Existing forms are unaffected: the new columns are
  nullable and nothing is backfilled.
- **From this release on, a type a newer release adds is skipped, not
  fatal.** `field_type` is now a `KilnCMS.Types.KnownAtom` (#2262), so a
  field whose type this release doesn't know is left out of the public form,
  the schema, submissions, the autoresponder's tokens and the builder (its
  machine name stays taken), and the CSV export lists its stored answers
  under a `(renamed or removed)` column. The rest of the form keeps
  working. That covers a node running beside a newer one, or after a
  rollback to this release. Releases before this one still fail to load such
  a form, which is why the next new type ships at least one release later
  ([New values in an atom column](releasing.md#new-values-in-an-atom-column)).

## Rendering

The `:form` content block references a form by slug:

- **On-site** pages render the live form server-side (inputs per field, a
  visually-hidden honeypot) POSTing to `/forms/<slug>`; a successful
  submission shows the form's success message on a thank-you page in the
  site's layout (header, footer, branding), for the same site and in the same
  language as the form. A submission to a form that is unknown or no longer
  active gets a 404 in the same layout. An inactive form renders
  nothing (a form or field edit drops the site's cached pages on every node
  at once, and a page that renders a form carries the form in its `ETag`, so
  a revalidating client sees the edit too). Kiln's own text in the form (the
  **Submit** label, "required", **Select…**, error messages, the
  human-verification widget) is in the article's language, the one its
  `<article lang>` declares, which a fallback page can make differ from the
  reader's `<html lang>`. On a multilingual site the block posts to
  `/<locale>/forms/<slug>` in that language, the default language's included
  (`/en/forms/<slug>`), so a refused submission re-renders and the thank-you
  page answers in the language the visitor was reading. A single-language
  site and the editor previews post to the bare `/forms/<slug>`. A theme
  stylesheet or analytics rule that matched the form by its `action` should
  match the `.kiln-form` class instead.
- **Fired `:web` artifacts** carry `<div data-kiln-form="<slug>"></div>` —
  headless frontends fetch the schema from `GET /api/forms/<slug>` (fields,
  labels, types, options, honeypot field name, submit URL, and the
  human-verification widget's details in `challenge` when the form asks for
  a check) and POST JSON to `/api/forms/<slug>` (`{ok: true}` or
  `{ok: false, errors: {...}}`). Each field in the schema carries `min`,
  `max` and `step`: a number's own settings, `1` and the star count (5 when
  unset) for a rating, and `null` for every other type. When the form asks
  for a check, the POST carries the widget's token as `_kiln_challenge` and
  the answer adds `challenge` (`"verified"` or `"held"`); see
  [Headless sites](human-verification.md#headless-sites). The placeholder is
  the same whatever the form's human-verification setting. Each field also
  carries its `condition` (`null` when it has none), and a JSON answer lists
  under `discarded` the fields whose values were dropped because their
  condition hid them; see
  [Headless front ends](#headless-front-ends).
- **The form's own page**, `GET /forms/<slug>` (#2138), renders an active
  form with no content around it: its name, description and fields inside the
  site's layout. See [below](#share-a-form-at-its-own-address).
- **A form with a field condition** loads one more small script, which
  shows and hides its fields as the visitor answers; with no script every
  field is shown. See
  [Without JavaScript, and in previews](#without-javascript-and-in-previews).

## Edit and rename form fields

Each field has a **label**, which visitors see, and a **machine name**, the
key its value is stored under in every submission. The machine name is also
what the CSV export's columns, the `form.submitted` webhook's `data`, the
`GET /api/forms/<slug>` schema and the autoresponder's `[field:<name>]` tokens
use. You can change it at any time, but a submission keeps the keys it was
received with, so read step 5 before renaming a field on a form that already
has entries.

You need the **admin** role: the Forms pages are admin-only.

1. Open **Forms** (`/editor/forms`) and click the form's name. The builder
   opens on its **Fields** tab, with the palette (**Add a field**), a preview
   of the form, and **Field settings** side by side on a wide screen. Each
   field on the preview shows its machine name in small monospace text under
   it.
2. Click a field on the preview. **Field settings** shows its **Label**,
   **Machine name**, **Type**, **Width**, **Required**, **Default value** and
   **Help text**, plus the settings its type takes: **Options — one per
   line** for a dropdown, radio buttons or a checkbox group; **Min**,
   **Max** and **Step** for a **Number (range)**; **Stars** for a rating; and
   **Placeholder** for every type but a checkbox, a dropdown, radio buttons,
   a checkbox group, a rating and a hidden field.
3. Edit a value. Most inputs save as you type or choose; **Machine name**
   saves when you leave the input. To save straight away, press Enter in any
   input or click **Save** at the bottom of the panel. After a save that
   changed something, the panel says **Saved.**, and a new machine name
   appears under the field on the preview.
4. If a value is refused, it stays in the input as you typed it, marked as
   invalid, with the reason underneath. Fix it and save again. A refused value
   does not hold up the other inputs: a label you change meanwhile still
   saves. Selecting another field or closing the panel discards the refused
   value and shows what is stored.
5. If you renamed a field on a form that has received entries, the panel also
   says *Entries already received keep the old key “email”.* (with the old
   name). Kiln does not rewrite stored submissions: entries received before
   the rename are keyed by the old name, and entries from now on by the new
   one.
6. If the **Confirmations** subject or body used the field's old token, the
   panel also says *The autoresponder now uses [field:full_name] where it used
   [field:string].* (with the two names). Kiln has rewritten the template in
   the same save; see
   [Autoresponder tokens follow a rename](#autoresponder-tokens-follow-a-rename).

For example, renaming `string` to `full_name` on a contact form that has two
entries and an autoresponder subject of `Thanks, [field:string]!`: the preview
shows `full_name` under the field, the panel says *Saved.*, *Entries already
received keep the old key “string”.* and *The autoresponder now uses
[field:full_name] where it used [field:string].*, the **Confirmations** tab
shows `Thanks, [field:full_name]!`, and the next submission is stored as
`{"full_name": "…"}` while the two earlier ones stay `{"string": "…"}`.

### Read entries after a rename

The **Entries** tab lists each submission's values under the current field's
label, with its machine name beside it, in the order the fields appear on the
form. A key that no current field has (left by a field that was renamed or
deleted) is not hidden: it appears in a dashed box headed **From a renamed or
removed field**, under its raw key.

So after the rename above, the two earlier entries show their value in that
box under `string`, and new entries show it under the field's label, with
`full_name` beside it.

**Export CSV** on the same tab keeps the old keys too. After the current
fields' columns, in form order, it adds one column per old key the exported
entries carry, headed with the key and ` (renamed or removed)`, sorted by key,
then `status`, `spam_score` and `submitted_at`. An entry with no value under a
column leaves that cell empty. After the rename above, the export's header is:

```csv
full_name,string (renamed or removed),status,spam_score,submitted_at
```

The two earlier entries have their value in the `string (renamed or
removed)` column and an empty `full_name`; new entries are the other way
round. The suffix is always in English, whatever the admin's language,
because a spreadsheet or import script keys on the header the way it keys on
the machine names.

The extra columns come only from the entries being exported: with
**New**, **Reviewed** or **Spam** selected above the list, the export holds
only those entries (`?status=`), and only their old keys get a column. A
form whose fields were never renamed or removed, or a filter that leaves no
entry with an old key, exports exactly the current fields' columns, as
before.

### Autoresponder tokens follow a rename

Renaming a field rewrites every `[field:<old name>]` token in the
**Confirmations** subject and body to `[field:<new name>]`, in the same save
as the rename. Without that, the old token would render empty in every
confirmation email from then on, because no field has that name any more.

- **Exact tokens only.** Renaming `email` rewrites `[field:email]` and leaves
  `[field:email2]` alone.
- **On or off.** A template is rewritten whether **Email the submitter a
  confirmation** is ticked or not, so switching it on later does not find a
  token for a field that was only renamed.
- **One save.** If the template cannot be saved, the rename is refused too,
  and the field keeps its old name.
- **Older broken tokens stay.** A token left behind by a field deleted
  earlier, or by a rename before this release, is not repaired, and it does not
  hold up the rename of a different field. Fix it in the **Confirmations** tab;
  while the autoresponder is on, that tab refuses to save until every token
  names a current field.

The builder reloads the **Confirmations** tab with the rewritten template, so
a later save there does not write the old token back.

### What a rename does not carry over

- **Headless clients and webhook consumers.** `GET /api/forms/<slug>` and
  new `form.submitted` payloads carry the new name straight away; a frontend
  or integration that reads the old key needs changing at the same time.
- **Reusing an old name.** If you rename `email` to `work_email` and later
  give another field the machine name `email`, the old entries' `email`
  values show under that new field on the Entries tab, because the key
  matches it. **Export CSV** merges them the same way: they land in the
  `email` column, with no `email (renamed or removed)` column.

Kiln has no option to rewrite the keys in existing entries
([#2344](https://github.com/The-Verscienta/kiln_cms/issues/2344)).

### Delete a field the autoresponder uses

While the autoresponder is on, Kiln refuses to delete a field whose
`[field:<name>]` token is in the **Confirmations** subject or body: every
confirmation from then on would show nothing where the value was. To delete
such a field (admin role):

1. Click the trash icon on the field in the preview and confirm **Delete this
   field?**. The field stays, and a message at the corner of the screen says
   *The autoresponder uses [field:email]: remove it from the Confirmations
   template first.* (with the field's name).
2. Open the **Confirmations** tab and either remove the token from **Subject**
   and **Body**, or untick **Email the submitter a confirmation**. Click
   **Save**.
3. Go back to **Fields** and delete the field again. It disappears from the
   preview.

With the autoresponder off, a field is deleted even if the template names it.
The token then stays in the template, and the tab refuses to save with the
autoresponder switched back on until you remove or replace it.

Moving a field to another form (changing its `form_id`, which the builder does
not offer) is refused the same way while the old form's autoresponder is on and
uses the field's token, with an error on `form_id`.

### Pre-select an option with a default value

**Default value** fills the field in before the visitor touches it. For a
text field that is whatever you type; for the types below, the builder says
under the input what the public form does with it:

| Type | Default value | Hint under the input |
| --- | --- | --- |
| Checkbox | `true` checks the box | *Use "true" to pre-check the box.* |
| Dropdown, radio buttons | one option, spelled exactly as in **Options**; that option starts selected | *Must match one of the options exactly to pre-select it.* |
| Checkbox group | one option, spelled exactly as in **Options**; that one box starts checked | *Must match one of the options exactly; that one box starts checked.* |
| Rating | a whole number of stars, from 1 to **Stars**; that rating starts selected | *A whole number of stars, from 1 to the maximum, to pre-select that rating.* |

A default that matches nothing (`Red` for an option `red`, `3.5` stars) is
saved but pre-selects nothing.

### Reorder fields and copy a field

The order of the fields on the builder's preview is the order of the public
form. You need the **admin** role.

1. Open **Forms** (`/editor/forms`) and click the form's name. Hover over a
   field on the preview, or click it: a small toolbar appears at its top
   right, with a drag handle (arrows, labeled **Reorder field** and the
   field's label), a copy icon (**Duplicate field**) and a trash icon.
2. To move the field, drag it by the handle to its new place and drop it.
   The new order is saved as you drop, with no message.
3. To copy the field, click the copy icon. The copy appears right after the
   original, with the same label and settings and the next free machine name
   (`email_2` for `email`, then `email_3`), and its settings open in **Field
   settings**. Rename it there.

A new order is saved whole or not at all. Moving a field rewrites the
position of every field that moved, and if any one of them is refused,
none of them is moved: the preview goes back to the saved order, and a
message at the corner of the screen names the field, for example *Couldn't
save the new order, so nothing was moved. Fix the field “topic” and try
again: Invalid value provided for options: a select field must list at
least one option.*

That happens when a field was saved by an older release with a setting
Kiln now refuses, here a dropdown with no options. Click the named field,
fix the setting its error names (in this example, enter at least one line
under **Options — one per line**), and drag again. A field copied just
before such a refusal is kept, sharing its original's place in the order
until the reorder succeeds.

### Fix a field named website

The public form carries a hidden spam trap, an input named `website` that
people never see and spam bots fill in. A submission that fills it is thrown
away while the sender is told it went through. A field of your own with the
machine name `website` is filled by real visitors, so every submission that
answers it is thrown away the same way, and nothing tells you.

Kiln no longer lets a field take that name. A form that already has one
keeps rendering it, and its label, order, **Required** and other settings
still save, but the builder flags it until you rename it. You need the
**admin** role.

1. Open **Forms** (`/editor/forms`) and click the form's name. On the
   preview, the field shows **Reserved name**, with a warning icon, under its
   machine name.
2. Click the field. Under **Machine name**, **Field settings** says *“website”
   is reserved for spam protection: a visitor who fills this field has their
   submission discarded. Give it another machine name.*
3. Change **Machine name** to another name, for example `company_website`,
   and leave the input (or press Enter). The panel says **Saved.**, the new
   name appears under the field on the preview, and the **Reserved name** flag
   and the note go away.

The rename behaves like any other
([above](#edit-and-rename-form-fields)): `[field:website]` tokens in the
**Confirmations** template become `[field:company_website]`, and a headless
frontend that posts the old key needs the new one. The visitor's answers
that were thrown away before the rename are not stored anywhere, so there is
nothing to recover.

Until the field is renamed, Kiln refuses to change its **Type** (the
message is *is reserved for spam protection*, under **Machine name**), and a
renamed field cannot be named `website` again. Nothing changes for the spam
trap itself: `GET /api/forms/<slug>` still reports `"honeypot_field":
"website"`, and the public form still renders the hidden input.

### Fix a field named locale

A submission records the language it was sent in from a param named
`locale`, which a headless frontend sends in the request body (both client
libraries' `submitForm` / `submit_form` send their `locale` option that way).
A field of your own with the machine name `locale` posts its answer under that
same name, so the answer is also recorded as the submission's language. A
form asking *Preferred language* with a free-text answer of `Spanish,
please` records that as the language.

Kiln no longer lets a field take that name. A form that already has one
keeps working: it renders the field, the answer is stored with the entry like
any other, and `GET /api/forms/<slug>` lists the field. Until it is renamed,
the answer is also recorded as the submission's language, and the builder
flags the field. You need the **admin** role.

1. Open **Forms** (`/editor/forms`) and click the form's name. On the
   preview, the field shows **Reserved name**, with a warning icon, under its
   machine name.
2. Click the field. Under **Machine name**, **Field settings** says
   *“locale” is reserved for the submission's language: a visitor's answer to
   this field is also recorded as the language the submission was sent in.
   Give it another machine name.*
3. Change **Machine name** to another name, for example `preferred_language`,
   and leave the input (or press Enter). The panel says **Saved.**, the new
   name appears under the field on the preview, and the **Reserved name** flag
   and the note go away.

The rename behaves like any other
([above](#edit-and-rename-form-fields)): `[field:locale]` tokens in the
**Confirmations** template become `[field:preferred_language]`, entries
already received keep the old key, and a headless frontend that posts the
field's answer as `locale` needs the new name. It keeps sending `locale` for
the submission's language: that param, and the client libraries that send
it, are unchanged.

Until the field is renamed, Kiln refuses to change its **Type** (the message
is *is reserved for the submission's language*, under **Machine name**), and
no field can be named `locale` again.

### Errors you can see

| Message | Meaning |
| --- | --- |
| must be lowercase letters, digits and underscores, starting with a letter | The machine name has a capital, a space, a hyphen or another character outside `a-z`, `0-9` and `_`, or starts with a digit or underscore. |
| has already been taken | Another field on this form already has that machine name. Machine names are unique per form. |
| a select field must list at least one option | A dropdown's **Options** box is empty. Enter at least one option, one per line. A radio or checkbox group says "a radio field …" or "a checkboxes field …" instead. |
| options can't be blank | An **Options** line is empty. |
| options must be unique | Two **Options** lines are the same. |
| a checkboxes field can have at most 50 options | A checkbox group lists more than 50 options. |
| can't be more than the maximum (…) | A **Number (range)** field's **Min** is above its **Max**. |
| must be greater than zero | A **Number (range)** field's **Step** is zero or negative. |
| must be a whole number from 1 to 10 | A rating's **Stars** is not a whole number from 1 to 10. |
| a hidden field can't be required | Hidden fields are filled by the page or a script, never by the visitor, so **Required** is refused on them. |
| is reserved for spam protection | The machine name `website` is the honeypot input's, so no field of any type can take it, whether you add, rename or retype a field. A field that already has it is refused a change of **Type** too; give it another machine name first. See [Fix a field named website](#fix-a-field-named-website). |
| is reserved for the submission's language | The machine name `locale` is the param a submission's language is recorded from, so no field of any type can take it, whether you add, rename or retype a field. A field that already has it is refused a change of **Type** too; give it another machine name first. See [Fix a field named locale](#fix-a-field-named-locale). |
| Couldn't save the new order, so nothing was moved. Fix the field “topic” and try again: … | Shown when you drag a field: one of the fields that moved was refused, so no field was moved. See [Reorder fields and copy a field](#reorder-fields-and-copy-a-field). |
| The autoresponder uses [field:email]: remove it from the Confirmations template first. | Shown when you delete a field: the autoresponder is on and its subject or body uses this field's token. See [Delete a field the autoresponder uses](#delete-a-field-the-autoresponder-uses). |

An error that belongs to no input in the panel, such as a permission error,
shows as a message at the corner of the screen instead.

## Show or hide a field based on an earlier answer

A field can be asked only when an earlier answer calls for it: **Tell us
more** only when **Topic** is *Other*, a company name only when **I'm
writing as** is *a business*. The visitor sees the field appear and
disappear as they answer. A field its condition hides is not required, and
whatever was sent for it is dropped on the server, whatever the browser did
(#2262).

You need the **admin** role: the Forms pages are admin-only.

1. Open **Forms** (`/editor/forms`) and click the form's name. On the
   preview, check that the field whose answer decides comes **above** the
   field you want to show or hide. A condition can use only the answers to
   fields before it, so drag the deciding field up first if it is below
   ([Reorder fields and copy a field](#reorder-fields-and-copy-a-field)).
2. Click the field you want to show or hide. **Field settings** ends with a
   **Conditional logic** section. On the form's first field it says
   *Conditions use the answers to earlier fields. Add a field above this one
   first.* A **Hidden field** has no such section, because the visitor never
   sees it.
3. Click **Add a condition**. One row appears and is saved straight away,
   testing the first field of the form with **is** and, as its value, that
   field's first option (a dropdown, radio buttons or a checkbox group),
   **Checked** (a checkbox) or nothing. The section says **Saved.**, and the
   field on the preview now shows **Shown when…** under its machine name.
4. Set the row. **Action** is **Show this field** or **Hide this field**.
   The row's first menu lists only the fields above this one, by label. The
   second is the test, offered only where it fits the type of the field it
   tests:

   | Test | Fields it can test |
   | --- | --- |
   | **is**, **is not**, **is empty**, **is not empty** | every type |
   | **contains**, **doesn't contain** | single line text, paragraph text, email, phone, web address, dropdown, radio buttons, checkbox group, hidden field |
   | **is greater than**, **is less than** | number, number (range), rating, date |

   The value is a menu of the options for a dropdown, radio buttons or a
   checkbox group tested with **is** or **is not**, **Checked** or
   **Unchecked** for a checkbox, a date picker for a date, and free text
   otherwise. **is empty** and **is not empty** take no value. A checkbox
   group **is** an option when that box is among the ones ticked. Every
   change saves as you make it, and the section says **Saved.**
5. For more than one test, click **Add another** and set the new row, then
   choose **When**: **all of these match** or **any of these match**. The
   **×** at the end of a row removes it. **Remove condition** removes the
   whole condition, and the field is always shown again.
6. Click **Preview** in the builder's header (or open the form's page) to
   try it. The builder's own preview always shows every field; the public
   form shows the field only while the condition holds.

For example, a contact form with a **Topic** dropdown (`Sales`, `Support`,
`Other`) and, below it, a required **Details** single-line text field, with
this condition on **Details**: **Show this field**, **Topic** **is**
`Other`. Details is stored with:

```json
{"action": "show", "rule": {"field": "topic", "op": "eq", "value": "Other"}}
```

A condition with one row is stored as that one test; with several, as
`{"all": [...]}` or `{"any": [...]}`. A visitor who picks `Sales` never sees
Details and can send the form without it; the entry holds
`{"topic": "Sales"}`. One who picks `Other` is asked for Details, and it is
required.

### How a condition is applied

The browser and the server apply the same rules, held to the same test
cases (`test/support/fixtures/form_visibility_cases.json`, and
`conditions_cases.json` for the tests themselves):

- **In form order, earlier fields only.** A condition can name only fields
  above its own, so no chain of conditions can loop. Saving is refused
  otherwise.
- **A hidden field has no answer.** A later condition that tests a hidden
  field sees it as empty, whatever the visitor typed before it was hidden.
  That is what lets conditions chain: hide **Topic**, and a field shown when
  Topic is `Other` hides too.
- **Hidden means not asked.** A hidden field is never required, and the
  value sent for it is not stored, not shown to the spam checks, not in the
  notification email and not in the `form.submitted` webhook. Its
  `[field:<name>]` token in the autoresponder is blank. The server works this
  out again from what was sent, so a visitor who un-hides a field in their
  browser, or a script posting straight to the form, gets nothing stored for
  a field its condition hides.
- **A condition Kiln can't apply leaves its field shown**, with its own
  **Required**: one that names a field that is gone or no longer above it
  (left by an older release, or written outside the builder), or one a newer
  release wrote with an action this release does not know. The preview
  marks such a field **Condition names a removed field**. For a field that
  is gone or below, its **Conditional logic** section says *This condition
  names a field that isn't before this one any more, so the field is always
  shown.*; for an action this release doesn't know, *This condition was set
  up outside the builder and can't be edited here.* Click **Remove
  condition** and add it again.
- **One level in the builder.** A condition written outside the builder (from
  code) can also use `in` (one of a list), `starts_with` and `ends_with`,
  and nest `all` and `any` up to 3 levels and 10 parts (tests and groups
  together). The builder shows
  such a condition as *This condition was set up outside the builder and
  can't be edited here.*, applies it, and offers only **Remove condition**.
- **Values are public.** The values a condition compares with are in the
  public page's HTML and in `GET /api/forms/<slug>`, so anyone can read them.
  Never put a secret in one, such as a discount code the visitor has to
  type to reveal a field.

The condition has its own **Action** rather than reusing the `visible_when`
rule of custom fields, because the rule engine has no "not": a hide rule
stored as a negated show rule could not be read back as the rule the admin
wrote.

### Rename, reorder or delete a field a condition uses

Conditions follow the form's fields:

- **Rename** a field and every condition that tests it is rewritten to the
  new machine name in the same save. The panel says *Conditions on “Details”
  now use subject.* (with the fields' labels and the new name).
- **Drag** a field below one whose condition tests it, or a field with a
  condition above the field it tests, and nothing is moved: *Couldn't save
  the new order, so nothing was moved: “Details” is shown based on “Topic”,
  which would come after it: conditions can only use earlier answers*.
- **Delete** a field a condition tests and the field stays, with *is used in
  the conditions of “Details”: remove those conditions first*. Remove the
  condition on Details (or change its row to test another field), then
  delete.
- **Change the type** of a field a condition tests, to one that test doesn't
  fit (a text field tested with **contains** made a number), and **Type** is
  refused until you change the condition.
- **Change a field's type to Hidden field** and its own condition goes with
  the change.
- **Duplicate the form** and each condition is copied, naming the copy's
  fields, renamed `website_2` or `locale_2` included
  ([Duplicate a form](#duplicate-a-form)). A condition the copy couldn't
  apply, such as one naming a field that isn't copied, is left off: the
  original shows that field always anyway.

### Without JavaScript, and in previews

The public form is drawn by the server, and a small script then shows and
hides its fields. Until that script runs, or when the browser runs no
script:

- every field is shown;
- a field with a condition says *Depends on an earlier answer; leave it
  blank if it doesn't apply.* under it, and is never required by the
  browser. The server still requires it when its condition shows it, and
  still drops its value when its condition hides it, so a refused
  submission comes back saying which field is missing.

Once the script runs it hides that note, hides each field its condition
hides and disables its inputs (so they are neither checked nor sent), and
restores **Required** on a shown field. Content previews in the editor show
every field, as without a script, because a LiveView page update would
undo what the script sets.

The script is `/assets/js/challenge_static.js`, the one an embedded form
already loads for its human-verification widget. Only a form with a
condition loads it, from inside the form, as an external module (about
10.5 KB minified, 4 KB gzipped), on its own page, in a form block and in the
embed alike. Pages without such a form, and `public.js`, are unchanged, and
a form with no condition renders exactly as before. A theme stylesheet can
style the parts it adds: the form carries `data-kiln-enhance`, each field's
wrapper `data-kiln-field` (its machine name), a conditional one
`data-kiln-condition`, and the note the class `kiln-form-condition-hint`.

### Headless front ends

`GET /api/forms/<slug>` gives each field a `condition`: `null`, or
`{"action": "show" | "hide", "rule": ...}` as above. It is `null` for a
condition the server can't apply, so the field is always shown there too.
Evaluate the fields in order, and treat a hidden field as having no value
for the conditions after it. A front end that doesn't evaluate conditions
keeps working: a value it sends for a field the condition hides is dropped,
not refused, and the answer is still `{"ok": true}`, with the dropped fields
listed under `discarded`. See
[Embeddable forms](api.md#embeddable-forms) for the shapes.

### Before you upgrade or roll back

The release adds one nullable column, `form_fields.condition`, and nothing
is backfilled: every existing form works as before.

- **Add conditions only once every node runs this release.** An older node
  ignores conditions: it shows every field and requires each field marked
  **Required**. During a rolling deploy, a page drawn by a new node can be
  submitted to an old one, which refuses the submission because a required
  field the condition hid was left blank.
- **Before rolling back, look at the conditional fields that are
  required.** After a rollback every conditional field is shown, and a
  required one is required of every visitor again, whatever they answered
  before it. Untick **Required** on those fields first if that would block
  visitors who shouldn't be asked. The stored conditions are kept, and apply
  again once you upgrade.

### Condition errors you can see

The messages under **Conditional logic**, and the ones the builder shows
for a change elsewhere that a condition stops:

| Message | Meaning |
| --- | --- |
| names “Topic”, which comes after this field: conditions can only use earlier answers | The condition tests a field below this one. Drag that field above this one, or test another field. |
| names "topic", which is not a field on this form | The condition names a machine name the form doesn't have. Seen only for a condition written outside the builder. |
| can't depend on the field itself | The condition tests the field it is on. |
| can't test “Topic” with gt | That test doesn't fit the type of the field it tests (see the table in step 4). |
| a hidden field can't have a condition | A **Hidden field** is never seen, so it takes no condition. The builder removes the condition when you change a field's type to hidden. |
| is not a valid condition: … | The condition's shape is wrong, for example *has more than 10 conditions* or *nests more than 3 levels*. Seen only for a condition written outside the builder. |
| each value must be at most 1000 characters | A value in the condition is longer than 1,000 characters. |
| would depend on itself through other conditions | A chain of conditions would loop. The earlier-fields rule already prevents this; the check is a second line of defence. |
| is used in the conditions of “Details”: remove those conditions first | Shown when you delete the field: another field's condition tests it. Also refused when moving the field to another form. |
| the conditions of “Details” test this field in a way this type can't answer: change those conditions first | Shown under **Type**: the new type doesn't fit a test another field's condition makes on this one. |
| “Details” is shown based on “Topic”, which would come after it: conditions can only use earlier answers | A new order, or a new machine name that sorts a field differently at the same position, would put a field above the one its condition tests. When you drag, it follows *Couldn't save the new order, so nothing was moved:*. |
| its condition already names this field | A rename would give the field the machine name its own condition tests. |
| has a condition: remove it before moving the field to another form | Moving a field to another form (changing its `form_id`, which the builder does not offer) while it has a condition, which names fields of the form it is leaving. |

## Duplicate a form

A duplicate copies a form's settings and fields into a new, inactive form, so
you can start a similar form without building it again. Its entries are not
copied. You need the **admin** role.

1. Open **Forms** (`/editor/forms`). Under *Your forms*, find the form and
   click the copy icon on its row. Its tooltip reads *Duplicate* and the
   form's name, then *copies its settings and fields; its entries stay with
   the original.*
2. A message says *Form duplicated (inactive until you activate it).*, and a
   new row appears: the name with ` (copy)` after it, marked **Inactive**,
   with the slug `<slug>-copy` (`<slug>-copy-2` and so on when that is
   taken).
3. Click the copy's name to open it in the builder, change what differs, and
   tick **Active (accepting submissions)** on its **General** tab when it is
   ready.

The copy's **Confirmations** template, and whether it is switched on, follow
the original's. Each field's condition is copied too, naming the copy's
fields
([Rename, reorder or delete a field a condition uses](#rename-reorder-or-delete-a-field-a-condition-uses)).

A duplicate is made whole or not at all: the copy, every one of its fields
and its autoresponder are saved together, so a duplicate that fails leaves
no partial copy behind.

What the message can say besides:

- *… The field “website” was renamed “website_2” in the copy: that name is
  reserved for spam protection.* The original has a field named `website`
  ([Fix a field named website](#fix-a-field-named-website)). The copy's field
  is `website_2` (or the next free name), and its `[field:website]` tokens
  read `[field:website_2]`. The original is not changed.
- *… The field “locale” was renamed “locale_2” in the copy: that name is
  reserved for the submission's language.* The same for a field named
  `locale` ([Fix a field named locale](#fix-a-field-named-locale)): the
  copy's field is `locale_2`, and its `[field:locale]` tokens read
  `[field:locale_2]`.
- *Couldn't duplicate “Contact”, so nothing was created. Fix the field
  “topic” in this form and try again: Invalid value provided for options: a
  select field must list at least one option.* (with the form's and the
  field's names, and the field's error). A field of the original was saved by
  an older release with a setting Kiln now refuses, here a dropdown with no
  options. No copy exists. Open the original in the builder, click the named
  field, fix the setting its error names, and duplicate again. The same
  field also stops the original's fields being reordered
  ([Reorder fields and copy a field](#reorder-fields-and-copy-a-field)).
- A message with no field name, such as *"http://insecure.test" is not an
  allowed CSP source. …*, is about one of the original's settings, here an
  embedding origin on its **Embed** tab. No copy exists either: fix the
  setting in the original and duplicate again.
- *The copy's autoresponder stays off: its template names a field the copy
  doesn't have ([field:gone]).* (with the unknown tokens). The original's
  autoresponder is on, but its **Confirmations** subject or body names a
  field it no longer has. The copy is made, with its autoresponder off; a
  renamed `website` or `locale` token is still rewritten. Fix the template in
  the copy's **Confirmations** tab and switch it on there.
- *The copy's autoresponder stays off: its subject or body is blank. Fill
  both in the copy's settings to turn it on.* The original's autoresponder is
  on with an empty subject or body. The copy is made, with its autoresponder
  off; fill both in its **Confirmations** tab and switch it on there.

## Share a form at its own address

Every active form has a page of its own at `/forms/<slug>` on the site's
host, so you can link to it from an email, a social post or a QR code without
first making a content page to hold a form block. The page shows the form's
name as its heading, then its description and fields, inside the site's
header and footer, and posts to the same `POST /forms/<slug>` as a form block.

You need the **admin** role: the Forms pages are admin-only.

1. Open **Forms** in the console (`/editor/forms`). Under *Your forms*, each
   active form's row lists a **Hosted form** address, which is the form's page
   (for example `https://www.example.com/forms/contact`), beside its **JSON
   API** address and its embed code. An inactive form's row says it is not
   public yet instead.
2. Click the form's name to open the builder (`/editor/forms/<id>`). Under the
   form's name in the header you see the same address as a link.
3. If the header says **Not public while inactive.**, open the **General**
   tab, tick **Active (accepting submissions)** and click **Save**. The header
   now shows the address. A new form is active from the start.
4. Click the address, or **Preview** beside it. The page opens in a new tab,
   the way a visitor sees it.
5. Copy the address and share it. A visitor who submits the form sees a
   thank-you page inside the site's header and footer: the heading **Thank
   you**, the form's success message (or *Thanks — we got your message.*
   when it has none) and a **Back** link to the page they came from. A
   submission with mistakes comes back to the form page with each error
   shown against its field.

The address follows the form's **Slug** (General tab). Change the slug and
the old address stops answering, so shared links break; Kiln does not add a
redirect for it.

On a multilingual site the page answers under each language prefix too:
`/fr/forms/contact` renders the form in French and posts back to
`/fr/forms/contact`, so the thank-you page and any error messages stay in
French. The page's language comes from its address alone: the prefix, or the
site's default language when there is none, never the visitor's session.
The default language's prefix is kept on the way back, so `/forms/contact`
and `/en/forms/contact` both post to `/en/forms/contact` (with English as
the default): an unprefixed post takes its language from the visitor's
session and could answer an English page in French. The embed works alike:
`/fr/forms/contact/embed` posts to `/fr/forms/contact`, `/forms/contact/embed`
posts to `/en/forms/contact`, and a refused submission re-renders inside the
frame in the language it was posted under. A single-language site keeps the
bare `/forms/contact`.

What the page sends with it:

| Header | Value | Why |
| --- | --- | --- |
| `Cache-Control` | `public, max-age=60, stale-while-revalidate=300` | The page changes only when an admin edits the form. A form deactivated within that minute refuses the submission anyway. |
| `Vary` | `Accept-Language` | Kept as published HTML sends it. The text Kiln adds around your form (the default **Submit** label, the site's chrome) follows the address's language prefix, which is already part of the cache key. |
| `X-Robots-Tag` | `noindex` | A form is somewhere a link sends people, not content to find by search. The embed document carries `noindex` for the same reason, and forms are not listed in `sitemap.xml`. |

The page is not a route of its own. It is the last thing Kiln tries for a
`/forms/<slug>` address before answering 404, so anything else at that
address wins: a content type of your own whose path segment is `forms` keeps
its entries, and a path alias, a redirect, a locked page or a members-only
teaser at the address is served instead of the form. The form shows only
when none of those answer. Why it is not a route: [ADR 0059](decisions/0059-a-generated-page-is-served-only-as-the-last-fallback-of-the-404-funnel-not-as-a-route-or-a-reserved-segment.md).

What can go wrong:

- **404 at `/forms/<slug>`.** The form is inactive, the slug is wrong (slugs
  are exact, so check the General tab), or the form belongs to another site:
  each site serves only its own forms, on its own host. The miss is recorded
  like any other 404, so it shows on the **404s** tab of
  `/editor/redirects`.
- **A different page at the address.** Something else answers at
  `/forms/<slug>` first (above). Give the form another slug, or remove the
  alias or redirect.
- **"Form not found" after sending.** The form was deactivated, deleted or
  given a new slug between the visitor opening the page and sending it. The
  answer is a 404 inside the site's header and footer, headed **Form not
  found**, saying *This form doesn't exist or no longer takes submissions.*
  Nothing is stored.
- **No Back link on the thank-you page.** The link goes back to the page the
  visitor sent the form from, taken from the browser's `Referer`. It is left
  out when the browser sent none, when it names another host, or when its
  path starts with `//` or `/\`, which a browser would read as another host.

## Embedding on another site

The builder's **Embed** tab hands out a one-line snippet
(`<script src=".../embed.js" data-kiln-form="<slug>">`) that drops a
self-sizing iframe of `GET /forms/<slug>/embed` onto a third-party page.

**Choosing the form's language.** Without anything else the embedded form is
in the site's default language. On a multilingual site, add
`data-kiln-locale` to the snippet to pick another:

```html
<script src="https://cms.example.com/embed.js" data-kiln-form="contact" data-kiln-locale="fr"></script>
```

The frame then loads `/forms/contact/embed?locale=fr`: the labels Kiln adds
(the default **Submit**, the error messages) are in French, and the form
posts back to `/fr/forms/contact`, so a refused submission and the thank-you
message stay in French. The value is checked against the languages the site
serves. One it doesn't serve, or a typo, gets the default language rather
than an empty frame. A snippet without the attribute works as before. A
language prefix on the address itself (`/fr/forms/contact/embed`) still wins
over `?locale=`.

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

**The operator's list is a ceiling on a multi-org deployment** (#1133, #1618).
While `EMBED_ORIGINS_LOCKED` is on, `EMBED_ORIGINS` is the *most* any form or
org in the deployment may open as well as the default: a form's or org's own
list may narrow it (a subset, or "This site only") but every entry must be
covered by it — same scheme, same port, the same host or a subdomain of a
`*.`-wildcarded one. An admin who saves an entry outside it is refused, with
the message naming the refused entry and *not* the ceiling (which on a shared
deployment would list every other org's partners), and told to ask the
operator. The Embed tab and the site-wide embed settings say a cap exists when
one does. With the cap off nothing above changes; `EMBED_ORIGINS=*` under the
cap is a ceiling of everything, and an unset `EMBED_ORIGINS` under the cap
closes framing deployment-wide whatever a tenant writes.

**Unset, `EMBED_ORIGINS_LOCKED` turns itself on once a second organization
exists** (#1618). With one organization the operator and the org admin are the
same party, so the org's own lists stand; the create that makes the deployment
multi-org turns the cap on immediately, with no restart. `EMBED_ORIGINS_LOCKED=true`
caps a single-org install too, and `EMBED_ORIGINS_LOCKED=false` keeps every
org's list uncapped however many there are — the behaviour of every release
before 0.11.

**What that does to lists already saved.** Nothing is rewritten. A form's or
org's list that names a site outside `EMBED_ORIGINS` is clamped when the embed
page is served: the uncovered entries are dropped from `frame-ancestors`
(within a minute, the embed page's cache window), so those sites get a blank
iframe, and saving that list again — or any list naming them — is refused.
Other edits to the form still save. **If `EMBED_ORIGINS` is unset, the ceiling
is same-origin only, so every cross-site embed on the deployment stops** until
the operator lists the sites in `EMBED_ORIGINS` or sets
`EMBED_ORIGINS_LOCKED=false`. Kiln warns about clamped lists — by count, never
by origin or org — at boot, when the second organization is created, and on
`/editor/system`. Turning the cap off again restores the saved lists as they
were.

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

**An embedded form that asks for a human-verification check** (#2249) draws
the widget inside the iframe and loads one small script of its own,
`/assets/js/challenge_static.js` (the embed never loads `app.js`). Its
policy then gains the provider's sources in `script-src` and an explicit
`frame-src 'self' <provider sources>`, on the form, its thank-you page and a
refused re-render: `https://challenges.cloudflare.com` for Turnstile;
`https://www.recaptcha.net/recaptcha/` and `https://www.gstatic.com/recaptcha/`
in `script-src` and `https://www.recaptcha.net/recaptcha/` in `frame-src` for
reCAPTCHA; a plugin provider's own declared sources. Every other form's
embed policy is unchanged. The iframe is served from the site's own host, so the token is
solved there and the parent page's host needs no configuration.

## Abuse protection

No CSRF on the submission endpoints (they're anonymous, and fired artifacts
couldn't carry a token). Instead:

- **honeypot** — a hidden `website` input; a filled honeypot gets a *fake
  success* and stores nothing;
- **rate limit** — the tight per-IP `form` bucket (20/min);
- server-side validation of every declared field (unknown keys dropped);
- **human verification** (#2249), per form and off by default: with the
  form's **General** tab's "Ask visitors to complete a human-verification
  check" ticked, the form draws the operator's provider's widget
  (Cloudflare Turnstile, Google reCAPTCHA v2 or a plugin's) and every
  submission must carry its token. Only after the fields validate and the
  honeypot is empty is the token checked. A refused token gets the form back
  (`422`); a submission with no token, one solved on a host the deployment
  does not serve, or one the provider could not check is **held**: stored as
  `:spam` and never acted on. With a widget the visitor has to click
  (reCAPTCHA's checkbox), the first click on submit without a token asks
  them to complete it ("Complete the check above, then send again.") and the
  second sends. Needs the operator's provider; see
  [Public forms](human-verification.md#public-forms).

A browser submission that fails validation gets a `422` carrying the same form
again (#1683), on-site inside the public layout and embedded inside the iframe
document: the visitor's values for the form's own fields filled back in, each
error shown against its field (`aria-invalid`, `aria-describedby`), and a
focused summary on top that links to each field by its label. The honeypot is
always rendered empty. The JSON endpoint still answers `{ok: false, errors}`.

Following a summary link moves focus to the field, so the visitor can type or
choose straight away. For radio buttons, a checkbox group or a rating, the
link goes to the group's first option, and the page keeps the group's
question in view above it. A hidden field's error ("This value is too long.")
is listed without a link, because a hidden input cannot take focus.

The messages in the HTML form are Kiln's own sentences, in the form's
language. The JSON endpoint keeps returning the short English fragments as its
`errors` values, because clients match on them:

| HTML form says | `POST /api/forms/<slug>` returns |
| --- | --- |
| Enter a number of at least 0.5. | `must be at least 0.5` |
| Enter a number of at most 10. | `must be at most 10` |
| Enter a number in steps of 0.25. | `must be a multiple of 0.25` |
| Choose a rating from 1 to 5. | `must be a rating from 1 to 5` |
| This value is too long. | `is too long` |

The number keeps the server's form (`0.5`, never `0,5`) in every language,
because it is the value the visitor has to type and a number input takes a
period. A step counts from the field's minimum, so the HTML says "in steps
of".

## Spam moderation (#477)

Post-storage triage on top of the pre-storage defenses above: every accepted
submission is scored by the `Kiln.Forms.SpamCheck` registry (the
`Kiln.Advisory` shape, adapted to a weighted score instead of a
severity-tiered finding — see the module docs for the plugin contract).
Shipped core checks:

| Check | Signal | Weight |
| --- | --- | --- |
| `LinkDensity` | 3+ links in the free-text fields | 40 |
| `DisallowedKeywords` | matches the org's own keyword list (`FormSpamSettings`, edited on `/editor/forms/settings`) | 50 |
| `FillTime` | submitted in under 1.5s of the form rendering (a signed, unforgeable "now" token rides in a hidden field) | 30 |
| `LocaleMismatch` | predominantly non-Latin script against a Latin-script declared locale | 35 |

Weights sum; a submission at or past `Kiln.Forms.SpamCheck.threshold/0`
(default 50) is stored `:spam` — never a hard reject, since the score can be
wrong and the row is still worth an admin's eyes. A `:spam` submission never
reaches the autoresponder or the `form.submitted` webhook (see Side effects
below); everything else about it — CSV export inclusion, retention — is an
admin decision, not automatic.

A submission **held** by human verification (#2249) has the threshold added
to its score, so it is always `:spam`. That is done by the scorer itself,
not by a registry check, so a plugin cannot unregister or reweigh it; checks
do see the outcome as the `:challenge` fact
(`Kiln.Forms.SpamCheck.Context.fact/3`: `:passed`, `:missing`,
`:wrong_host`, `:unavailable`, or `nil` when the form asked for none). The
Entries tab marks each entry of a form that asks with a **Verified** or
**Held** badge; the CSV export does not carry it.

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

Each accepted submission that wasn't scored `:spam` (held submissions
included, above) optionally mails
`notify_email` (Oban `:mail` queue, HTML-escaped), optionally autoresponds to
the submitter (below), and fires the `form.submitted` webhook event
(selectable per endpoint at `/editor/webhooks`) with `{form: slug, data: {...}}`; values are typed per the table under [Field types](#field-types), so a `checkboxes` answer is a list and a `number` or `rating` a number.

The two mails are background jobs that carry the form's, site's and
submission's ids, never what the visitor typed (#2992). Each worker reads the
stored submission when it runs, through `FormSubmission`'s `:for_delivery`
read as the form pipeline's system actor, so the mail always shows the
submission as it is stored. That also means:

- A submission **deleted**, or **marked spam** on the Entries tab, before its
  job runs sends no notification and no confirmation. The job completes
  without sending.
- The notification goes to the form's `notify_email` as it is when the job
  runs, and none goes if it was cleared in the meantime (as before).
- If the read is refused (the system actor lost its grant), the job fails and
  retries rather than treating the submission as deleted.
- An address on a **suppression list** is sent nothing (#3051). Before it
  sends, each worker asks the instance-wide list and the form's site's own
  about the address it is about to mail: the form's `notify_email` for the
  notification, the submitter's address for the autoresponder. A listed
  address is skipped: the job completes without sending, so it is not among
  the delivery failures on `/editor/mail` or `/editor/site-mail`. This holds
  for jobs queued by an earlier release too.
- If a suppression list cannot be read, the job fails and retries rather
  than sending past it. Its stored error does not name the address.

A job usually runs within seconds of the submit, so these matter mostly when
mail is retrying after a failed delivery (up to five attempts over about 81
minutes). Jobs queued by the release before this one carry the submitted data
themselves and are delivered from it; that data is dropped from the job's row
once it finishes. See [Job args retention](data-flows.md#job-args-retention).

**When a form's notifications stop arriving**, check whether the
`notify_email` address is suppressed. A relay that hard-bounced it once put
it on a list, and every notification since has been skipped. The instance-wide
list is under **Delivery health** on `/editor/mail` (platform admins); the
site's own is under **Delivery health** on `/editor/site-mail` (the site's
admins). **Remove** the entry once the mailbox works again. Each skipped
notification logs a warning that names the job, the form and the site, never
the address:

```text
form notification job 4182 not sent: form 5f0e2a7c-3b1d-4c8e-9a61-2d7b8e4f1c90's notify address is suppressed (org 0c4d6e2a-8b7f-4a19-b3e5-71f2c9d0a6b4); clear it on /editor/mail or /editor/site-mail
```

A skipped confirmation logs at info level, because the visitor typed that
address and a bounced one is the list doing its job:

```text
form autoresponder job 4183 not sent: the submitter's address is suppressed (form 5f0e2a7c-3b1d-4c8e-9a61-2d7b8e4f1c90, org 0c4d6e2a-8b7f-4a19-b3e5-71f2c9d0a6b4)
```

### Autoresponder (#468)

The builder's **Confirmations** tab can turn on a confirmation email back to
the *submitter* — separate from `notify_email`, which mails the admin.
It only ever fires when the form declares an `:email` field *and* the
submission filled one in (`KilnCMS.Forms.Autoresponder.eligible?/3` is the one
place that decides this, so the send path and the config-time validation
below can't drift on it); a `:spam`-scored submission is excluded the same as
`notify_email` and the webhook.

The confirmation goes to the **first `:email` field, in form order, that the
submission gave a value** (#2262). A field its condition hid has no value, so
it is passed over, and so is an optional one left blank: on a form with an
optional personal address and, shown only to business customers, a work
address, the confirmation goes to the personal address when it was given and
to the work address otherwise. Before
this release only the form's first email field counted, so a blank first
email field meant no confirmation even when a later one was filled in. A
`[field:<name>]` token for a field its condition hid expands to nothing,
like a field left blank. On a form with a condition the **Confirmations** tab
says so: *A field its condition hid leaves its token blank. The confirmation
goes to the first email field that was shown and filled in.*

It is asked twice: when the submission is accepted, so a submission with no
one to confirm queues no job, and again when the job runs, against the form
and its fields as they are then (#2992). So a confirmation is not sent if,
between the submit and the job, the autoresponder was switched off, or the
`:email` field was deleted or renamed (the stored submission keeps the old
field name, so it no longer has a value under the new one). It goes to the
address stored in the submission, never one carried in the job.

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

The template follows the form's fields (#2343). Renaming a field rewrites its
exact `[field:<old>]` tokens to `[field:<new>]`, enabled or not, in the
rename's own transaction (`KilnCMS.CMS.Changes.RewriteAutoresponderTokens` on
`FormField`'s `:update`); that write skips the token check above, so a stale
token from an earlier delete cannot refuse the rename of another field.
Deleting a field, or moving it to another form, is refused while the
autoresponder is on and uses its token
(`KilnCMS.CMS.Validations.AutoresponderFieldInUse`). Both live on the resource,
so every writer of `FormField` gets them, not only the builder. See
[Autoresponder tokens follow a rename](#autoresponder-tokens-follow-a-rename)
and [Delete a field the autoresponder uses](#delete-a-field-the-autoresponder-uses).
