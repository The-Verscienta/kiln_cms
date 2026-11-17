# 0046. A section's layout is its own row, keyed by the section name, not a setting on each field

- **Status** — accepted (2026-11-13), recording the choice that shipped with
  #2496 in 1.9.0. Amended 2026-11-16 by
  [#2652](https://github.com/The-Verscienta/kiln_cms/issues/2652) and
  [#2881](https://github.com/The-Verscienta/kiln_cms/issues/2881) (every
  field write keeps the layouts in step at once, see "Amendment").
- **References** — [#2280](https://github.com/The-Verscienta/kiln_cms/issues/2280)
  and [#2496](https://github.com/The-Verscienta/kiln_cms/pull/2496), which
  built it; [#2656](https://github.com/The-Verscienta/kiln_cms/issues/2656),
  which asked for this record;
  [#2652](https://github.com/The-Verscienta/kiln_cms/issues/2652) and
  [#2881](https://github.com/The-Verscienta/kiln_cms/issues/2881), the paths
  that applied the lifecycle rule below late or not at all, closed by the
  amendment;
  [ADR 0047](0047-the-field-sync-file-stays-version-1-and-a-new-attribute-does-not-bump-it.md)
  for the field sync file that carries the layouts.
- **Changelog** — [1.9.0](../changelog/v1.9.0.md#field-layout); the
  amendment in the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md)
  ([Fixed](../changelog/unreleased.md#section-layouts-kept-in-step) and
  [Breaking](../changelog/unreleased.md#field-sync-section-entries-stricter)).

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
count (`KilnCMS.CMS.SectionLayouts.carried/2`, which also counts a field of a
type the release does not register). `SectionLayouts.prune/2` reads the
fields and the rows fresh, not from a page's loaded copy, so one admin's
prune does not destroy a layout another admin has just set, and its reads
fail closed: a read the actor may not make is an error, never an empty list
that would make every layout look uncarried. Where the rule is applied (as
amended by #2652 and #2881):

- **Every field update or destroy.** `KilnCMS.CMS.FieldDefinition`'s
  `:update` and `:destroy` run `KilnCMS.CMS.Changes.KeepSectionLayouts`. When
  the write takes a field out of a section (its `section` renamed or cleared,
  its owner changed, or the field deleted), the change reads where the field
  is now, locked, inside the write's transaction, and after the write calls
  `SectionLayouts.prune/2` with `only:` the section it left. The prune runs
  as the field write's own actor in the record's org, in the same
  transaction; if it is refused, the field write fails with
  `KilnCMS.CMS.Errors.SectionLayoutNotKept` and rolls back. This covers the
  fields admin's edit and delete, `KilnCMS.CMS.JoinGraduation.retire/2`,
  and any code interface call.
- **Renaming a section.** The fields admin's **Save** passes
  `carry_section_layout?: true` to `:update`. Before the prune, the change
  calls `SectionLayouts.carry/4`, decided from a fresh read made after the
  rename: if no top-level field still carries the old name and the old name
  has a non-default row, the new name gets that layout when it has no row
  (or only a default one); a new name with a layout of its own keeps it.
  The prune that follows then drops the old row, whichever way the carry
  went, unless a field still carries the old name. A field sync import does
  not ask for the carry: its file declares the layouts itself.
- **Saving a section's layout.** The **Sections of** panel at
  `/editor/fields` (`KilnCMSWeb.FieldDefinitionLive`, the `section_layout`
  event) writes the row, or deletes it when it is set back to the default,
  then calls `SectionLayouts.prune/2` for the whole owner, which drops every
  row no field carries.
- **Field sync export.** `KilnCMS.CMS.FieldSync.export/1` writes an owner's
  `"sections"` only for rows that some top-level field of that owner carries
  and that are not at the default (`KilnCMS.CMS.FieldSection.default?/1`).
- **Field sync import.** The import's field writes pass
  `section_layouts: :deferred`, so the per-write prune waits: a swap (one
  field from A to B, another from B to A) would otherwise drop a layout
  halfway through. Once every write has run, in the same transaction and in
  a dry run too, `SectionLayouts.prune_names/2` prunes the sections the
  import's fields left (moved out of, or deleted) and the sections the file
  lays out. The plan lists those deletes. An entry at the default creates
  nothing and deletes the stored row of that name. A non-default entry for a
  section no top-level field carries once the import is done is refused at
  plan time, so nothing is written. With `--prune`, an owner whose file
  carries a `"sections"` key loses the rows the file does not list. An owner
  without the key keeps its rows, except a section its own field writes leave
  empty.
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

- **A stale row could wake up, until #2881.** As built in 1.9.0, the rule
  said "eventually": between the moment a section lost its last field and
  the next prune, the row stayed, and a field filed under that name again
  took the old layout, in the editor and in the schema export, because both
  match by name. The prune now runs in the same transaction as the write
  that empties the section, so a new orphan cannot appear; see "Amendment".
- **Rows orphaned before the amendment stay.** A row a 1.9.x or 1.10.x
  release left behind is pruned only by the type's next **Sections of**
  save, or by a field sync import whose file lists that section at the
  default layout or, with `--prune`, carries the owner's `"sections"` key
  without it. If no field of the type
  has a section any more, the panel is not shown and nothing in the console
  removes the row.
- **A layout can be lost to a race.** A field created in a section at the
  same moment as a prune that saw the section empty renders that section
  with the default layout.
- **A row can still be created with no carrier.** `FieldSection`'s own
  `:create` does not check that a field carries the name, because a sync
  import writes its sections before its fields. The console only offers
  sections that fields carry, and the import refuses a ghost entry, so only
  a direct code interface call (`CMS.create_field_section/2`) can make one.
- **A field write can now fail on its layout.** A refused prune or carry
  fails the field write with `KilnCMS.CMS.Errors.SectionLayoutNotKept` and
  rolls it back, rather than leaving an orphan. The layout writes and the
  field write are both admin-only, so the field write's own policy refuses
  first in the ordinary case.
- **Field sync carries the rows as their own list** per owner, with their own
  `?`, `~` and `-` lines in the diff
  ([field-sync.md](../field-sync.md)), and refuses an entry no field carries,
  as it refuses an unknown key.

## Amendment (2026-11-16, #2652 and #2881): the field write keeps its layouts

In 1.9.0 and 1.10.0 each caller kept the layouts itself: the fields admin's
delete and rename events, and a field sync import's deletes. Five paths left
a row behind, which a later field of that name inherited:
`JoinGraduation.retire/2`; a rename onto a section that already had a
layout; clearing a field's section; a sync import that moved a field to
another section; and a sync file listing a section no field carries. The
rename carry also decided from the page as loaded, so with another admin
editing the same type it could move a layout that another field still used,
or leave one that nothing did.

The rule in this record is unchanged. Where it is applied moved into the
resource: one change on `FieldDefinition`'s `:update` and `:destroy`, so
every path, present and future, prunes in the field write's own transaction,
from a locked, fresh read. The carry is opt-in on the action, since only the
console means "rename this section" by a field edit. Field sync defers the
prune to one reconcile at the end of its transaction, refuses a ghost entry
at plan time rather than storing or silently dropping it, and treats an
entry at the default as "no row", as the console always did. Rejected along
the way: patching the five callers one by one (it leaves an owner move and
any future caller open), hiding uncarried rows at read time (a later field
still inherits the row), and pruning with `authorize?: false` (it would
bypass the per-row policy).

See [Lay out custom fields as tabs, fieldsets or columns](../extending-content.md#lay-out-custom-fields-as-tabs-fieldsets-or-columns).
