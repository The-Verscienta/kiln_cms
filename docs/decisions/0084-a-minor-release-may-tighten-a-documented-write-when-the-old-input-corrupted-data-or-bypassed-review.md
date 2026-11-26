# 0084. A minor release may tighten a documented write when the old input corrupted data or bypassed review

- **Status** — accepted (2026-11-25), recording a rule three releases had
  already followed.
- **References** — [#2743](https://github.com/The-Verscienta/kiln_cms/issues/2743)
  (custom-field value shapes, 1.10.0);
  [#2768](https://github.com/The-Verscienta/kiln_cms/issues/2768)
  ([#3389](https://github.com/The-Verscienta/kiln_cms/pull/3389),
  [#3399](https://github.com/The-Verscienta/kiln_cms/pull/3399): the Portable
  Text check on `block_tree`);
  [#3347](https://github.com/The-Verscienta/kiln_cms/pull/3347) (MCP
  `update_*` refusing published records);
  [ADR 0049](0049-a-write-that-names-an-editor-input-the-field-does-not-offer-is-refused.md)
  (an explicit write is checked, never tidied);
  [ADR 0083](0083-a-portable-text-body-is-checked-against-its-published-schema-at-block-tree-and-repaired-elsewhere.md)
  (where the Portable Text check sits).
- **Changelog** — the Unreleased section of
  [CHANGELOG.md](../../CHANGELOG.md), under Breaking
  ([long form](../changelog/v1.13.0.md#portable-text-write-check)) and Fixed
  ([long form](../changelog/v1.13.0.md#mcp-live-records-draft-only)); the
  precedent in [1.10.0](../changelog/v1.10.0.md#custom-field-api-stricter-shapes).

## The problem

Since 1.0.0 the covered surfaces are a promise. The README ("What 1.0 means
for API stability") and [the overlay contract](../overlay-contract.md) carry
the same table: on a **Covered** surface, "a rename, a removal or a change of
meaning needs a major release and goes through the deprecation path".
`/api/json`, `/gql` and `/mcp` are on it, "reads and documented writes". The
[API guide](../api.md) ("Versioning & stability") is stricter for HTTP: a change
that "alters documented response semantics" is introduced under an `/api/v1/…`
prefix, with the old paths kept for at least two minor releases and six
months.

Read literally, that makes every write that used to succeed a write that must
keep succeeding until 2.0. Three times now a write that succeeded did harm:

- **#2743, 1.10.0.** An empty list sent for a single custom field cleared
  it, and a list sent for a single text field had its items joined into one
  string. Each answered `200` and stored something the client did not mean.
  (#2739 refused list operands that were joined into one filter pattern in
  the same release, by the same reasoning.)
- **#2768, 1.13.0.** A `block_tree` body with an object `marks` entry, an
  object `style` or a non-numeric list `level` was stored. The mark was
  silently ignored, the list nested at whatever depth the value happened to
  compare as, and the editor's Markdown view could fail on it. Most of its
  sibling shapes were worse: stored, then the page answered 500 and the record
  could not be saved again.
- **#3347, 1.13.0.** `update_page`, `update_post` and `update_entry` over
  `/mcp` wrote a published record's live row and re-fired it, so a model's
  edit reached readers at once, on a site where only admins publish, although
  `docs/mcp.md` said MCP authoring was draft-only.

Keeping any of these until 2.0, or behind an `/api/v1` that only the broken
input would use, means shipping the damage for months to keep a promise
nobody relied on knowingly.

## Decision

A **minor** release may refuse input that a documented write used to accept,
when accepting it did one of these:

- **stored data that broke reads**: a page that answered 500, a record that
  could not be opened or saved again, an artifact that failed to fire;
- **corrupted content**: stored something other than what the client sent,
  or silently dropped part of it (a cleared field, joined list items, an
  ignored mark);
- **let a change skip review**: put an edit in front of readers through a
  path that the documentation, or the site's own workflow, says waits for a
  person.

Such a change must:

- be listed under **Breaking** in `CHANGELOG.md`, which `mix kiln.update`
  prints before it moves a pin, with the request before and after, and in the
  release's What's new guide with the code before and after;
- refuse with an error that names what is wrong and, where there is one, the
  replacement: a path into what was sent (`block_tree[0].body[0].children[0].marks[0] must be a string (got an object)`),
  a field and its rule, or the tool to use instead
  (`use the save_*_working_copy tool`);
- write nothing when it refuses;
- keep accepting whatever converts without loss, as ADR 0049 and ADR 0083
  do: a number in a text slot becomes its text, a numeric-string `level` an
  integer;
- leave stored data readable. A row the old rule let in is repaired on read
  (ADR 0083) or left as it is; it is never made unreadable by the new rule;
- be safe to roll back. An older release accepts the input again.

Where a replacement is needed, it ships in the same release: #3347 added the
three `save_*_working_copy` tools beside the refusal.

## What does not qualify

Anything that is not one of the three harms above still needs a major
release or, for HTTP, an `/api/v1/…` prefix and the deprecation window:

- **Renames**, of an attribute, an argument, an action, a tool, an event or an
  error `code`.
- **Reshaped responses**: a field moved, retyped or removed, a list that
  becomes an object, an error that moves from `errors` to the result.
- **New required input for convenience**: a field made required because a
  default is awkward, or an argument the server could work out for itself.
- **Tightening a write that was merely untidy**: input that was stored as
  sent and read back as sent, even if a stricter rule would be neater.
- **A rule the documentation never gave**, used to refuse input the
  documentation allowed.

If a case is arguable, it is not one of these: take the major-release path.

## Rejected

- **Hold every write until 2.0.** The promise is that a client that used the
  surface as documented keeps working. A client sending input that broke a
  page, dropped its own data or skipped review was not getting what it asked
  for; keeping that working protects nobody and keeps the harm in production
  for every other site.
- **Ship it under `/api/v1/…` and keep the old paths.** The old paths would
  be exactly the ones that keep storing bad data, for at least six months.
  The prefix exists for changes of meaning a working client depends on, and
  no working client depends on a `500` on its next read.
- **Coerce or tidy the bad input instead of refusing it.** That hides the
  client's mistake behind a `201` and can drop its content (ADR 0049, ADR
  0083). Where a value converts without loss it is coerced; anything else is
  refused.
- **Log a deprecation warning for a release first.** A warning in a server
  log does not reach an API client, and every request in the window still
  stores the damage. For #3347 it would have kept unreviewed edits going live.
- **Decide case by case, with no written rule.** That is what happened for
  #2743, and the 1.13 changes had to argue it again. A written rule also says
  what does *not* qualify, which a case-by-case call never does.
