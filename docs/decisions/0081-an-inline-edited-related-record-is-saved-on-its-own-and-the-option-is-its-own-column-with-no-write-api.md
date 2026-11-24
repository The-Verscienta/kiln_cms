# 0081. An inline-edited related record is saved on its own, and the option is its own column with no write API

- **Status** — accepted (2026-11-23). Pull request 1 of #2283 shipped the
  option and a read-only record card; part 2a adds saving from the card
  (the notes under "What part 2a adds"). The unsaved-changes guard and the
  cascade come in later pull requests of the same plan.
- **References** — [#2283](https://github.com/The-Verscienta/kiln_cms/issues/2283),
  [the plan](https://github.com/The-Verscienta/kiln_cms/blob/main/docs/plans/inline-reference-editing-plan.md) (I1, I2, I12 and the
  owner's decisions of 2026-11-16), building on
  [ADR 0048](0048-a-fields-editor-input-is-an-editor-only-string-separate-from-its-text-format.md)
  (editor-only settings) and [ADR 0047](0047-the-field-sync-file-stays-version-1-and-a-new-attribute-does-not-bump-it.md)
  where it applies.
- **Changelog** — the Unreleased section of
  [CHANGELOG.md](../../CHANGELOG.md), under Added
  ([long form](../changelog/v1.12.1.md#edit-inline-option)).

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
Saving every changed card when the parent is saved is the cascade (one commit at
a time, stop at the first failure, parent not written), built in part 2b.

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

## What pull request 1 shipped

The option (column, validation, sync, export annotation, the fields-admin
checkbox) and a read-only card on each connected row the actor may write.

## What part 2a adds

The card edits the record and saves it on its own, as decided above. The
choices that carry weight:

- **No `AshPhoenix.Form` per card.** The card holds a params map of the
  changed editable keys and calls `ContentTypes.update/4` (a draft) or
  `ContentTypes.save_working_copy/4` (a published record, with the title as
  `working_title`), then maps the Ash errors to inputs itself. A form per
  open card would hold a changeset in the LiveView for up to ten cards and
  validate on every keystroke for a result the save recomputes anyway.
- **A server-side whitelist.** A save takes only the keys of the card's
  editable set: the title (when the actor's grant allows it and the type has
  no title template) and the plain custom fields the actor's grant allows,
  not hidden by a read grant or a condition. Any other posted key is
  dropped, so a forged event cannot widen the write.
- **Staleness is checked by state as well as `lock_version`.** Workflow
  writes keep `lock_version`, so a record published since the card read it
  would pass a version check. The draft write passes
  `kiln_if_match: [{lock_version, state}]`, the card re-reads the record
  before writing, and both a stale-record error and a failed precondition
  show as *Changed by someone else*.
- **The card is inert when the parent field is disabled.** The picker sits
  in a disabled group in that case, so the card's inputs and Save are
  disabled. The decision above stands: the server would accept the write
  under the related record's own policy, since the parent field's grant
  governs only the connection. Only the interface does not offer it.

Added in part 2b: the unsaved-changes guard, the cascade on the parent's Save and
workflow steps, and expanding a record on create.

## Rejected

- **A new `widget` value.** A zero-migration shortcut, but it would make
  "dropdown" and "inline" exclusive and bend ADR 0048's rule that a widget
  never changes what the editor can do to *other* records.
- **One transaction for parent and children.** Reasons above.
- **A nested write input on the JSON:API, GraphQL or MCP surfaces.** It would
  bring back the shared-transaction question, merge two resources' errors into
  one path and need one `expected_lock_version` per child in one request. If
  there is demand it is its own issue and record.
