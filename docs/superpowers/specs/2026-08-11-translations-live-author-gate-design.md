# TranslationsLive author gate (#1156)

## Problem

`KilnCMSWeb.TranslationsLive` (`/editor/translations`) shows a `+ Missing`
create-translation chip on every coverage cell with no record, and
`handle_event("create_translation", …)` always calls
`Translations.create_translation_with_notes!/4`.

An editor scoped to `editable_types: ["post"]` therefore sees a create chip on
every `page` row whose only possible outcome is the policy refusal flash
*"Couldn't create that translation."* — the dead-button class #926 fixed on the
content list and #922 fixed inside `ContentEditorLive`.

The create policy (`Checks.EditableContentType`) already refuses; the UI and
handler do not mirror that question.

## Decision

**Keep coverage rows for types the actor may read but not author.** Hide only
the create affordance. Existing locale chips keep linking to their editors.

This preserves a read-only view of translation coverage while removing the
button whose only outcome is an error flash.

## Approach

Local gate in `TranslationsLive` (do not extract a shared helper in this
change). Mirror `EditorLive`'s `may_author?/3` + `type_name_of/1`, which ask the
same question as `Checks.EditableContentType`:

- `:admin` → may author
- `:editor` → `Scoping.permitted?(actor, org_id, :editable_types, type_name)`
- otherwise → may not
- dynamic types compare as `"entry"`

### Row data

Each row built in `load_rows` / `row/…` gains:

```elixir
may_author?: may_author?(actor, org.id, ct)
```

### Template

- Missing + `row.may_author?` → existing `<button phx-click="create_translation">`
- Missing + not `row.may_author?` → non-interactive `<span>` with the same
  missing chip classes and `status_label(:missing)` (no `+`, no click)
- Existing variants → unchanged links

### Handler

Before creating, resolve the content type for `kind` and refuse when
`may_author?` is false with `{:noreply, socket}` and **no flash** — same
silent refusal pattern as `ContentEditorLive`'s `may_write?` gate.

Ash create policy remains the authorization boundary; the LiveView gate is
usability (and forged-event hygiene), not a second policy engine.

## Testing

In `test/kiln_cms_web/live/translations_live_test.exs`, a scoped editor
(`editable_types: ["post"]`) with admin-created `page` and `post` sources:

1. Page row is present; no create button for that page id.
2. Post row still offers create for a missing locale.
3. Forged `create_translation` for the page produces no `#flash-error` and no
   new page translation.

Existing admin happy-path tests stay green.

## Out of scope

- Extracting shared `may_author?` for `EditorLive` + `TranslationsLive`
- Hiding unauthorable rows entirely
- XLIFF export checkbox / import behavior
- #1175 (`editable_types: ["entry"]` vs dynamic types)

## Files

- Modify: `lib/kiln_cms_web/live/translations_live.ex`
- Modify: `test/kiln_cms_web/live/translations_live_test.exs`
