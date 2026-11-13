# 0047. The field sync file stays version 1, and a new attribute does not bump it

- **Status** — accepted (2026-11-13), recording the choice that shipped with
  #2437, #2495 and #2496 in 1.9.0.
- **References** — [#2288](https://github.com/The-Verscienta/kiln_cms/issues/2288)
  and [#2437](https://github.com/The-Verscienta/kiln_cms/pull/2437) (field
  sync); [#2284](https://github.com/The-Verscienta/kiln_cms/issues/2284) and
  [#2495](https://github.com/The-Verscienta/kiln_cms/pull/2495) (`widget`);
  [#2280](https://github.com/The-Verscienta/kiln_cms/issues/2280) and
  [#2496](https://github.com/The-Verscienta/kiln_cms/pull/2496) (`width` and
  `sections`); [#2656](https://github.com/The-Verscienta/kiln_cms/issues/2656),
  which asked for this record;
  [ADR 0046](0046-a-sections-layout-is-its-own-row-keyed-by-the-section-name-not-a-setting-on-each-field.md)
  for the section layouts the file carries.
- **Changelog** — [1.9.0](../changelog/v1.9.0.md#field-definition-sync), with
  [field layout](../changelog/v1.9.0.md#field-layout) and
  [field widgets](../changelog/v1.9.0.md#field-widgets).

## The problem

`mix kiln.fields.export` writes a JSON document marked
`"format": "kiln-field-definitions"` and `"version": 1`
(`KilnCMS.CMS.FieldSync`, `@version 1`). A field in it carries every
attribute the `FieldDefinition` create action accepts, read from the action
by `FieldSync.field_keys/0`, so an attribute added to the resource is
exported without touching `FieldSync`. The importer is strict the other way:
`parse/1` refuses a key it does not know (`unknown key(s) width`), so a typo
is not silently dropped, and fills a key the file leaves out with the
attribute's default.

Field sync merged first. Two changes then added to the document while it
stayed at version 1: `width` on every field and a `"sections"` list per owner
(#2496), and `widget` on every field (#2495). A build from before them
refuses a file from after them. #2656 asked whether that should have bumped
the version, so that an older build says the file is too new instead of
naming a field.

## Decision

**The document stays version 1.** No released build disagrees with another
about what version 1 means:

- Field sync (#2437, merged 2026-11-08), `widget` (#2495, 2026-11-09) and
  `width` with `sections` (#2496, 2026-11-09) all merged after 1.8.0
  (2026-11-03) and first shipped together in 1.9.0 (2026-11-11). 1.9.0's image
  was published but never announced, so 1.9.1 is the first announced 1.9;
  either way, every 1.9 build carries all three. 1.8.0 has no `FieldSync` at
  all, and there was no 1.9.0 release candidate.
- `field_sync.ex`, `field_definition.ex`, `field_section.ex`,
  `type_definition.ex`, `field_widgets.ex`, `section_layouts.ex` and
  `promotion.ex` are unchanged from 1.9.0 to 1.9.2.
- Release images are built only from `vX.Y.Z` tags
  (`.github/workflows/release.yml`).

So every build that can read or write the file accepts and writes the same
keys. A file without `width`, `widget` or `"sections"` came only from an
unreleased `main` between those merges. A released build reads such a file
anyway: a field without `width` is full width, one without `widget` gets the
type's default input, and an owner without `"sections"` leaves the target's
layouts alone, even with `--prune`.

**For the future, the version changes only for a change a released reader
would misread**: a key whose meaning or value changes, a key that moves, a
nesting that changes shape. A new attribute is not such a change. A released
reader refuses a file carrying it by the unknown key, names the field, and
writes nothing; a newer reader fills the attribute's default into an older
file. This is the rule [field-sync.md](../field-sync.md) already stated
before this record.

`test/kiln_cms/cms/field_sync_version_test.exs` pins the keys version 1
carries (field, section layout and dynamic type). A change to any of them
fails that test, and its message asks for one of three decisions: leave the
attribute out of the document, keep version 1 under the rule above, or bump.

## Rejected

- **Bump to 2 now.** It would announce a break no released pair of builds
  ever had. It would also break every file 1.9.x has written:
  `FieldSync.parse/1` matches `"version" => @version` exactly, so a version-2
  reader refuses a version-1 file as `unsupported document version 1`. A
  future bump therefore needs a reader that accepts every version up to its
  own, not only the new one.
- **Bump on every new attribute.** Each bump would cost the same as above for
  a change older readers already refuse loudly and safely. The unknown-key
  refusal names the key, which tells an operator more than "made by a newer
  Kiln" would.

## Consequences

- A file exported by a later release that adds a field attribute is refused
  by 1.9.x with one `unknown key(s)` error per field. Export from the older
  build, upgrade the target, or strip the key
  ([field-sync.md](../field-sync.md#moving-a-file-to-an-older-build)).
- Importing an older file into a newer build resets the new attribute to its
  default on every field that has another value, and the dry run lists it as
  `~`. That is what a pre-release file without `widget` does to chosen
  inputs today.
- A change that does need a bump must also teach the reader the older
  versions, since released files are version 1.
