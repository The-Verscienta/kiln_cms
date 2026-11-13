# 0046. A section's layout is its own row, keyed by the section name, not a setting on each field

- **Status** — accepted (2026-11-13), recording the choice that shipped with
  #2496 in 1.9.0.
- **References** — [#2280](https://github.com/The-Verscienta/kiln_cms/issues/2280)
  and [#2496](https://github.com/The-Verscienta/kiln_cms/pull/2496), which
  built it; [#2656](https://github.com/The-Verscienta/kiln_cms/issues/2656),
  which asked for this record;
  [#2652](https://github.com/The-Verscienta/kiln_cms/issues/2652) for two
  places the lifecycle rule below is applied imperfectly;
  [ADR 0047](0047-the-field-sync-file-stays-version-1-and-a-new-attribute-does-not-bump-it.md)
  for the field sync file that carries the layouts.
- **Changelog** — [1.9.0](../changelog/v1.9.0.md#field-layout).

## The problem

A custom field has always been filed under a **section**: the free-text
`section` string on `KilnCMS.CMS.FieldDefinition`. Fields with the same string
are one section, and the section sits where its first field sits. There is no
section record; the name is the section.

#2280 asked for a way to show a section as a tab, an always-open fieldset or
an accordion, and to say whether an accordion starts open. That is a property
of the section, not of any one field, and the section has nowhere to keep it.
Three places were possible:

- **A `display` (and `initially`) on every field definition.** Every field of
  `Clinical` would carry `display: :tab`, and the editor would read the first
  one's.
- **A map on the type**, from section name to layout.
- **A row of its own per laid-out section**, keyed by the type and the section
  name.

## Decision

**A section's layout is a `KilnCMS.CMS.FieldSection` row, keyed by its owner
(a compiled `content_type` or a dynamic `type_definition_id`, exactly one) and
the section `name`, within the site.** It holds `display` (`:accordion`,
`:fieldset`, `:tab`) and `initially` (`:auto`, `:expanded`, `:collapsed`) and
nothing else. A section without a row is an `:auto` accordion, which is how
every section rendered before #2280, so a type nobody lays out looks as it
did. The fields admin deletes a row set back to that default rather than
storing it. Grouping itself does not move: a field's `section` string still
decides which section it is in.

That makes the layout keyed by a name that lives somewhere else, so it comes
with a lifecycle rule:

> **A layout row whose name no top-level field of its owner carries is never
> exported and is eventually pruned.**

Link fields and group sub-fields have no section, so only top-level fields
count (`KilnCMS.CMS.SectionLayouts.carried/2`). `SectionLayouts.prune/2`
reads the fields and the rows fresh, not from a page's loaded copy, so one
admin's prune does not destroy a layout another admin has just set. Where the
rule is applied:

- **Saving a section's layout.** The **Sections of** panel at
  `/editor/fields` (`KilnCMSWeb.FieldDefinitionLive`, the `section_layout`
  event) writes the row, then calls `SectionLayouts.prune/2` for the whole
  owner, which drops every row no field carries.
- **Deleting a field.** The fields admin's `delete` event calls
  `SectionLayouts.prune/2` with `only:` the deleted field's section, so the
  last field of a section takes its layout with it.
- **Renaming a section.** When an edit renames the last field still carrying
  a section, `carry_section_layout/3` in the same LiveView recreates the row
  under the new name and deletes the old one, unless the new name has a row
  already.
- **Field sync export.** `KilnCMS.CMS.FieldSync.export/1` writes an owner's
  `"sections"` only for rows some top-level field of that owner carries.
- **Field sync import.** A field the import deletes takes its section's layout
  with it, as in the console (`SectionLayouts.prune/2` after every delete has
  run). With `--prune`, an owner whose file carries a `"sections"` key loses
  the rows the file does not list. An owner without the key, a file from
  before layouts, keeps its rows untouched.
- **Promotion.** `mix kiln.promote_data` moves the rows from the dynamic type
  to the compiled one in the same transaction as the fields
  (`KilnCMS.CMS.Promotion`, `rescope_field_definitions/2`), so neither side
  is left with layouts for fields it no longer has.

The readers that apply a layout, the editor's Custom fields panel
(`KilnCMSWeb.ContentEditor.CustomFieldsPanel.layout/2`) and the schema export
(`x-kiln-section-display`), look a row up by the section names the fields
carry, so a row nobody carries renders and exports nothing.

## Rejected

- **A `display` on every field.** Twelve fields of one section would carry
  twelve copies of one choice, and nothing would stop them disagreeing: an
  edit to one field, a field sync file edited by hand, or a field added with
  the default would give the section two layouts, and the editor would have
  to pick one. Changing a section's layout would be a write to every field of
  it. #2280 also warned against the per-field, per-widget configuration
  sprawl it found in other systems.
- **A map on the type.** A compiled content type is code; it has no row to
  hold a site's settings, and its layout differs per site. The map would
  need a new per-site, per-type table anyway, and a JSON map in that table
  gives up the per-section unique key, the per-row policy and the per-row
  diff and prune that field sync does for fields.

## Consequences

- **A stale row can wake up.** The rule says "eventually": between the moment
  a section loses its last field and the next prune, the row stays. If a
  field is filed under that name again before then, the section takes the old
  layout, in the editor and in the schema export, because both match by
  name. Nothing is lost, but an admin may see a tab they did not set.
- **Not every path prunes at once.** As built in 1.9.0, these leave a row
  behind until the type's next **Sections of** save, or for good if no field
  of the type has a section any more, since the panel is then not shown:
  - `KilnCMS.CMS.JoinGraduation.retire/2` destroys a graduated field without
    pruning its section.
  - A field edit that moves the last field of a section to no section, or to
    a section that already has a layout, leaves the old row; the rename carry
    covers only a move to a name with no row. The carry also decides from the
    page as it was loaded (#2652).
  - A field sync import that changes a field's `section` prunes nothing
    without `--prune`. An import also creates a row for any section the file
    lists, carried by a field or not, and a row at the default layout (#2652).
- **Field sync carries the rows as their own list** per owner, with their own
  `?`, `~` and `-` lines in the diff
  ([field-sync.md](../field-sync.md)).

See [Lay out custom fields as tabs, fieldsets or columns](../extending-content.md#lay-out-custom-fields-as-tabs-fieldsets-or-columns).
