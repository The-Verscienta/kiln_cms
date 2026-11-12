# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Changed

<a id="form-field-name-website-reserved"></a>

- **No form field of any type can be named `website` any more, and the form builder flags a field that already is.**
  `website` is the name of the hidden spam-trap input every public form
  carries, and a submission that fills it is discarded with a fake success.
  A field of your own with that machine name is filled by real visitors, so
  every submission that answered it was silently thrown away. 1.9 refused the
  name only on the field types it added; it is now refused on every type,
  when a field is added, renamed or has its type changed. A field that
  already carries the name keeps working as before (label, order,
  **Required** and other edits still save), but the builder shows
  **Reserved name** under it on the preview and a note under **Machine
  name** in its settings until it is renamed; its type can't be changed
  until then, as 1.9 already refused for the new types. Admins: open each
  form in the builder and rename any flagged field
  ([Fix a field named website](../forms.md#fix-a-field-named-website)). The
  spam trap itself is unchanged: `GET /api/forms/<slug>` still reports
  `"honeypot_field": "website"`. `FormField` has no JSON:API or GraphQL
  write surface, so only code that calls `KilnCMS.CMS.create_form_field`
  or `update_form_field` with that name sees the new refusal, *is reserved
  for spam protection* on `name`. (#2267)

## Fixed

<a id="form-duplicate-autoresponder"></a>

- **Duplicating a form whose autoresponder is on and uses `[field:…]` tokens works again, and a field that can't be copied is named instead of dropped.**
  The copy was created with the autoresponder on before any of its fields
  existed, so the token check found no field and refused the whole
  duplicate. The copy is now created with the autoresponder off, its fields
  are copied, its renamed tokens are written, and then it is switched on in a
  separate write checked against the copy's own fields. A field named `website` is copied as `website_2` (or
  the next free name), and the copy's `[field:website]` tokens follow; the
  message says so. A field the copy refuses is listed in an error message,
  and when the copy's autoresponder can't be switched on (its template names
  a field that wasn't copied) it stays off with the reason shown. (#2267)

<a id="form-errors-translated"></a>

- **Number and rating errors on a public form read as translated sentences, such as "Enter a number of at least 0.5.", and the builder explains what a default value does for dropdowns, radio buttons, checkbox groups and ratings.**
  The bounded refusals (at least, at most, step, rating range) and a hidden
  field's "is too long" reached the HTML form as raw English fragments. The
  HTML form now shows them in the form's language, with the bound as the
  server writes it (`0.5`, which is what a number input takes). The JSON
  endpoint `POST /api/forms/<slug>` returns the same English fragments as
  before (`must be at least 0.5`), because clients match on them. The
  builder's **Default value** input now has a hint for a dropdown or radio
  buttons (an exact option match pre-selects it), a checkbox group (that one
  box starts checked) and a rating (a whole number of stars), joining the
  checkbox's, and the hint is announced with the input. (#2269)

<a id="form-error-summary-focus"></a>

- **A public form's error summary links now move focus to radio buttons, checkbox groups and ratings, landing on the group's first option.**
  The links pointed at the group's `<fieldset>`, which cannot take focus,
  so following one scrolled the page but left focus behind, and a keyboard or
  screen-reader user had to find the field again. The link now targets the
  group's first input, with a scroll margin that keeps the group's question
  in view. A hidden field's error is listed as plain text, since a hidden
  input can never take focus. (#2268)

<a id="form-thank-you-site-layout"></a>

- **The thank-you page after a form submission on the site, and its "Form not found" page, now show the site's header, footer and branding, in the form's language.**
  They were a bare card with none of the site around it, unlike the form
  page and its error re-render. Both now render in the site's public layout
  for the same site and language; the 404 is headed **Form not found** and
  says *This form doesn't exist or no longer takes submissions.* A tripped
  spam trap's fake success gets the same page as a real one. The page inside
  an embed's iframe is unchanged. The **Back** link is also left out when
  the referring path starts with `//` or `/\`, which a browser reads as
  another host. (#2338)
