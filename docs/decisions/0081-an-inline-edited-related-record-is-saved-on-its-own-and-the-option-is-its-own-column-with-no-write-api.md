# 0081. An inline-edited related record is saved on its own, and the option is its own column with no write API

- **Status** — accepted (2026-11-23). Pull request 1 of #2283 ships only the
  option and a read-only record card; saving from the card and the cascade
  come in later pull requests of the same plan, and this record is the
  reasoning they build on.
- **References** — [#2283](https://github.com/The-Verscienta/kiln_cms/issues/2283),
  [the plan](https://github.com/The-Verscienta/kiln_cms/blob/main/docs/plans/inline-reference-editing-plan.md) (I1, I2, I12 and the
  owner's decisions of 2026-11-16), building on
  [ADR 0048](0048-a-fields-editor-input-is-an-editor-only-string-separate-from-its-text-format.md)
  (editor-only settings) and [ADR 0047](0047-the-field-sync-file-stays-version-1-and-a-new-attribute-does-not-bump-it.md)
  where it applies.
- **Changelog** — the Unreleased section of
  [CHANGELOG.md](../../CHANGELOG.md), under Added
  ([long form](../changelog/unreleased.md#edit-inline-option)).

## The problem

An editor who connects a record in a reference field often needs to fix a word
in that record, and today must leave the page, lose their place and come back.
Showing the related record's fields inside the parent's form invites the
obvious design, where the parent's Save writes both. That raises three
questions this record settles: where the option lives, what a "save" of a
related record is, and whether the API gets a matching nested write.

## Decision

**The option is its own nullable boolean column, `edit_inline`, on
`FieldDefinition`, not a value of `widget` (I1).** `widget` says how a value
is *chosen* (search or dropdown) and its values exclude each other. "Edit the
record I already chose" combines with either, so it is a separate attribute.
It is valid only on a top-level `:reference` (`Validations.ReferenceEditInline`
refuses a sub-field), is cleared on any other type and stores an unticked box
as nil (`Changes.ClearReferenceOptions`), so off has one stored form. The
migration is one nullable column with no default: the previous release never
reads it. Field sync carries it as an ordinary attribute, and the schema export
reports it as `x-kiln-edit-inline` when on. Graduating a field to a join
resource drops it: it describes the editor, not a column.

**A related record is saved on its own, with no shared transaction (I2).** The
card is a second, independent write to a second resource, under that
resource's own policies and `lock_version`, exactly as "Add new" already is.
Wrapping the parent and its children in one database transaction was rejected:
the parent's Save is already several writes (working copy flush,
`:save_working_copy`, `:update`), so there is no one changeset to wrap; Ash
actions inside a caller's transaction lose their notifications and their
`after_transaction` hooks (publish, webhooks, indexing) still escape it; row
locks taken in the order a person opened cards can deadlock against a
co-editor saving in the other order; and a long transaction holds a connection
while those hooks run. Each commit is a valid record by itself, so a failure
partway leaves consistent data, never a corrupt pair. The cost, accepted, is
that "all or nothing" is not offered; the card says which records were saved.
Saving every changed card when the parent is saved (a cascade, one commit at a
time) is planned for a later pull request on top of this, and is decided
there.

**The parent field's grant governs only the connection.** Whether an editor may
change a related record is decided by that record's own policies, per record,
not by the parent field. In this pull request that is already so for the
read-only card: it is offered only for a row the actor may write, and the
server decides again when a card opens.

**There is no write API (I12).** The option is editor-only, like `widget`: no
write path reads it to decide anything. A headless client composes the same
result from two authorized calls, writing the related record at its own
endpoint and then connecting it. A "write the child through the parent's
mutation" input is not offered.

## What this pull request ships

Only the option (column, validation, sync, export annotation, the fields-admin
checkbox) and a **read-only** card on each connected row the actor may write.
Nothing is editable yet.

## Rejected

- **A new `widget` value.** A zero-migration shortcut, but it would make
  "dropdown" and "inline" exclusive and bend ADR 0048's rule that a widget
  never changes what the editor can do to *other* records.
- **One transaction for parent and children.** Reasons above.
- **A nested write input on the JSON:API, GraphQL or MCP surfaces.** It would
  bring back the shared-transaction question, merge two resources' errors into
  one path and need one `expected_lock_version` per child in one request. If
  there is demand it is its own issue and record.
