# 0083. A Portable Text body is checked against its published schema at `block_tree` and repaired elsewhere

- **Status** — accepted (2026-11-25), PR 2 of #2768.
- **References** — [#2768](https://github.com/The-Verscienta/kiln_cms/issues/2768)
  ([#3389](https://github.com/The-Verscienta/kiln_cms/pull/3389), the render
  guards, was PR 1); [#2743](https://github.com/The-Verscienta/kiln_cms/issues/2743)
  for the scalar rule;
  [ADR 0049](0049-a-write-that-names-an-editor-input-the-field-does-not-offer-is-refused.md)
  (an explicit write is checked, never tidied);
  [ADR 0018](0018-a-site-may-only-lower-a-deployment-ceiling-refused-on-write-clamped-on-read.md)
  (refused on write, corrected on read);
  [#475](https://github.com/The-Verscienta/kiln_cms/issues/475) (table
  canonicalization); [#2683](https://github.com/The-Verscienta/kiln_cms/issues/2683)
  (1-based list item positions).
- **Changelog** — the Unreleased section of
  [CHANGELOG.md](../../CHANGELOG.md), under Breaking
  ([long form](../changelog/unreleased.md#portable-text-write-check)) and Fixed
  ([long form](../changelog/unreleased.md#portable-text-write-check-fixed)).

## The problem

A `:rich_text` field (a core `rich_text` block's `body`, or any plugin
block's `field :x, :rich_text`) is cast as a list of objects and nothing
more. Whatever a client put inside those objects was stored: a span whose
`marks` was a string, `children` that were a string, a `markDefs` entry that
wasn't an object, an object where `text` belongs. Most of those then raised in
every reader, so the public page answered 500, firing failed, and the record
could not be saved again. Kiln already publishes what a body should look like,
the `portable_text_block` definition in the exported JSON Schema
(`Kiln.Block.JsonSchema`), but nothing on the write path held a body to it.

PR 1 made every reader repair a body before rendering it
(`KilnCMS.Blocks.PortableText.Shape.repair_body/1`). That keeps a stored row
readable. It does not tell the client that sent the body that it was wrong:
the write answers 201 and the prose quietly goes missing.

There are two kinds of writer, and they need different answers:

- **A headless client** (JSON:API `block_tree`, GraphQL `blockTree`, the MCP
  `create_*`, `update_*` and `save_*_working_copy` tools) sends a body it
  built itself. If it is malformed, the client made a mistake and should hear
  about it.
- **An internal writer** (restore, promote, copy, translation, envelope
  import, the editor's save) writes back what is already stored, through the
  `blocks` attribute. A body stored before any check, or a version in history,
  can hold any of the bad shapes. Refusing it would make a record impossible to
  restore or publish for a reason its editor cannot see or fix.

## Decision

- **Refuse structural damage at `block_tree`, with a path.**
  `KilnCMS.CMS.Changes.ApplyBlocksInput` runs
  `KilnCMS.Blocks.PortableText.Shape.check_body/2` on every Portable Text value
  in the raw `block_tree` argument: a `rich_text` block's `body` (a JSON string
  is decoded first), any block's `:rich_text` field, and both nested in
  `columns`. A node, child or `markDefs` entry that isn't an object; `children`,
  `markDefs` or `marks` that isn't a list; an object or list in a string slot;
  and a `level` that isn't a whole number or numeric string are refused with an
  `InvalidAttribute` on `:block_tree`. Every content type's create, update and
  `save_working_copy` runs that change, and all three surfaces send the body
  through it, so each answers in its own shape (JSON:API `400`
  `invalid_attribute` at `/data/attributes/block_tree`, GraphQL `errors` with a
  null `result`, MCP `isError: true`) and nothing is written.
- **Coerce scalars, as #2743 does.** A number or boolean in a string slot
  becomes its text, and a numeric-string or whole-number `level` becomes an
  integer. That is the rule custom fields have followed since 1.10.0, which
  ADR 0049 records: an explicit write is checked, never tidied, except where a
  value converts without loss. A `null` entry in `marks` is dropped for the
  same reason: nothing is lost. The coerced body is the one that is cast and
  stored.
- **The schema decides, not the renderer.** The check refuses what crashes or
  misrenders a reader and what the published schema does not admit, and
  nothing else. A missing or `null` key is fine and none is ever added, so a
  valid body is stored byte for byte as sent. Keys the schema doesn't name are
  kept (`additionalProperties: true`). A custom `_type` is allowed, but its
  standard keys (`_key`, `style`, `children`, …) are still held to the
  schema: "custom" names the node's type, it does not exempt the node.
- **Repair everywhere else.** The `blocks` cast
  (`TypedBlocks.sanitize_attrs/1`, in `KilnCMS.CMS.TypedBlocks`) runs the same lenient
  `repair_body/1` every reader runs, then the existing sanitizing, on every
  `:rich_text` field, core or plugin. The stored cast
  (`TypedBlocks.to_union_stored/1`) repairs a `:rich_text` value before Ash
  casts it, so a body whose top-level node isn't an object loads again instead
  of failing the whole row. That is the ADR 0018 pattern: refused where a
  person is choosing the value, corrected where it is only being read or
  carried.
- **Plugin `:rich_text` fields are Portable Text.** They get the check, the
  repair and the link `href` scrub a core body gets. They were stored
  unchecked before, `javascript:` links included.
- **Paths are 0-based JSON paths into what was sent.**
  `block_tree[0].columns[1].blocks[0].body[2].children[1].marks`. A reason
  names the JSON type it found and never echoes the value. At most five are
  listed, then `and N more`.
- **No migration.** Stored rows are not rewritten. History is hash-chained and
  must stay as it was written, and repairing on read and on write-back already
  covers every row a migration would touch.

## Why at `block_tree` and not in the cast

The cast is the one place every writer passes through, so a check there would
catch the most. But it is also what restore, promote, copy and import write
back through, and there the body is not the caller's input: it is what the
database already holds. A strict cast would make a poisoned version
unrestorable and a poisoned working copy unpublishable, with an error about a
path the editor never typed. `block_tree` is the argument only a client's own
fresh input arrives in, so the check sits there and the cast repairs. A client
that bypasses `block_tree` by writing `blocks` directly is an Elixir caller
inside the application, which gets the repair.

A body sent as a TipTap document (`{"type": "doc", …}`, the editor's shape)
is converted by `PortableText.from_tiptap/1` in the cast and then repaired, not
checked. A path into the converted Portable Text would point at nodes the
client never sent.

## Why tables stay lenient

#475 made the cast canonicalize a table: a row or cell that isn't an object is
dropped, and a numeric-string `colspan` is coerced. Clients that build a table
from the DOM rely on that, and a row the renderer would have skipped anyway
does not lose prose. Refusing those now would break working table writes
without fixing any crash. The spans and `markDefs` inside a cell are checked
like a node's, because a bad span there did crash the renderer.

## Why 0-based paths when #2683 counts from 1

#2683 made list-field errors say `item 2` for the second item, because those
messages are read by an editor in the field editor, where items are numbered
from 1 on screen. A `block_tree` path is read by a developer against the JSON
they sent, and `body[1]` there is what their language indexes. Mixing the two
in one message (`body[2]` for the second node) would send them to the wrong
node.

## Rejected

- **Coerce everything.** Turning `children: "text"` into a span, or an object
  `text` into `""`, behind a 201 hides the client's bug and can drop their
  prose. It also contradicts the #2743 rule.
- **Check in the `blocks` cast.** See above: internal writers would fail on
  rows nobody can fix.
- **Validate with the exported JSON Schema.** A generic validator cannot
  express the coercions or the lenient tables, would refuse `"text": 42`, and
  reports in its own terms rather than as a path into `block_tree`.
- **Check in the SDK's `:rich_text` type.** The field's Ash type lives in
  `kiln_plugin`, so a check there would need an SDK release, and its stored
  cast would refuse rows already at rest.
- **A data migration.** History cannot be rewritten, and repair on read and on
  write-back already covers the live rows.
