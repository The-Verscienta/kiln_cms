# 0082. A field's text reaches the `:llm` and `:json_ld` artifacts only when its container opts in with `deliver_llm`

- **Status** — accepted (2026-11-24). The last pull request of the
  flexible-content plan (issue 2282, PR 7 of 7).
- **References** — [#2282](https://github.com/The-Verscienta/kiln_cms/issues/2282),
  [the plan](https://github.com/The-Verscienta/kiln_cms/blob/main/docs/flexible-content-plan.md) (section 6 and decision 2 of
  section 10), building on
  [ADR 0060](0060-an-artifact-change-bumps-format-version-only-when-every-existing-document-needs-it.md)
  (when an artifact change bumps `format_version`),
  [ADR 0047](0047-the-field-sync-file-stays-version-1-and-a-new-attribute-does-not-bump-it.md)
  (the field-sync file) and
  [ADR 0065](0065-a-flexible-field-keeps-its-mixed-items-inline-and-its-item-types-are-field-definitions.md)
  (flexible fields, whose "What is not done yet" section this record supersedes as far
  as the fired surfaces go).
- **Changelog** — the Unreleased section of
  [CHANGELOG.md](../../CHANGELOG.md), under Added
  ([long form](../changelog/v1.13.0.md#deliver-llm)).

## The problem

The fired `:llm` Markdown and the fired `:json_ld` node are what answer
engines and crawlers read. Neither carried any custom field except
geolocation, so a page built from a flexible field (an FAQ, a set of
sections) or from a group showed an answer engine only its blocks. The plan
promised that flexible items would reach both surfaces, applying to custom
text generally, groups included, and left the option's name and the format to
this pull request.

## Decision

**The option is a boolean column, `FieldDefinition.deliver_llm`, default
false.** It is named after its neighbours, `deliver_plain` and
`deliver_portable`, and the admin screen calls it **Include in AI-readable
outputs**. Off by default means every existing artifact is byte-for-byte what
it was, so **`format_version` does not change** (ADR 0060: bump only when every
existing document needs the new shape; here none does). Flipping the flag, or
deleting a flagged field, re-fires the type's published documents
(`Changes.BustTypeRegistry`), and so does anything that changes what the
artifact says: a flagged field's `label` or `position`, and the creation,
deletion or change of `label`, `position`, `item_setting` or `field_type` on a
nested row or item type whose owner chain reaches a flagged field. A nested
write under an unflagged field re-fires nothing.

**The flag lives on the container, never on a sub-field.** It is allowed on a
top-level `:string`, `:text`, `:flexible` or `:group` field.
`Changes.ClearDeliverLlm` clears it on any other type, on a sub-field and on
an item type, and `Validations.PrivateField` refuses it on a private field, as
it refuses `deliver_plain` and `deliver_portable`: each copies the value
somewhere public. A flagged container contributes **every text sub-field**
(`:string`, `:text`; nested flexible and group rows too), skipping sub-fields
marked `item_setting` (presentation, not content). Numbers, media,
references, enums and the like are out of scope for now. The consequence is
stated in the admin help text and the guides: ticking a group or flexible
field makes all of its text sub-fields public. A per-sub-field flag was
rejected: it needs the flag on three resource shapes and a control per
sub-field; a container-level opt-in is the plan's "generic opt-in" and a
finer control can follow.

**One module walks the values, both surfaces render from it.**
`KilnCMS.Firing.AnswerText.entries/1` reads the resolved custom fields
(`KilnCMS.Firing.CustomFields`: private values already dropped, an unreadable
reference snapshot masked) and returns one entry per flagged top-level field,
in position order. `LlmMarkdown.compose/3` and the engine's `:json_ld`
composition both render from those entries, so the two surfaces cannot
disagree about what a document says. An item whose `_type` has no definition,
and a key no definition names, are ignored and never printed raw. A rich
`:text` field becomes plain paragraphs (`KilnCMS.PlainText`). Empty values
contribute nothing, and a field left with no text gets no heading and no
element.

**The `:llm` format** adds, after the blocks, one section per flagged field:
`## <field label>`. A text field is a paragraph; a group is one
`**<sub-field label>:** text` paragraph per text sub-field; a flexible field
is, per item, a `### <item type label>` heading and the same lines (a nested
item is one heading level deeper, at most `######`).

**The `:json_ld` format** adds `hasPart` to the main node, a list of
schema.org `WebPageElement`s (`hasPart` is a `CreativeWork` property):

```json
{"@type": "WebPageElement", "name": "Question", "text": "Answer text"}
```

A text or group field is one element named by the field's label; a flexible
field is one element per top-level item, named by its item type's label, with
nested items' text flattened into it in order. An Event-family type carries no
`hasPart`, by the rule that already withholds `articleBody` and the bylines
from it. Nothing else in the fired node sets `hasPart` today; if a value is
there, ours is appended (a lone map is wrapped in a list).

**Caps.** At most 50 `hasPart` elements, and at most 5,000 characters in one
element's `text` or one `:llm` section, cut at a word boundary with `…`
(`AnswerText.max_elements/0`, `max_chars/0`). They bound the artifact, which
is fired and cached whole, against a flexible field with hundreds of items.

**Accepted divergence: the served page's own JSON-LD is unchanged.**
`KilnCMSWeb.StructuredData`, which writes the inline `<script
type="application/ld+json">` on Kiln's own pages, does not read `deliver_llm`.
The fired `:json_ld` artifact (`GET /api/content/:type/:slug?surface=json_ld`)
is the surface this record extends; a page's markup carries the page's visible
content already, and a second, differently shaped copy of the fields inside it
would be duplicate-content structured data. An overlay theme that wants the
elements in its own markup can read them from the artifact.

**No `format_version` bump, and the field-sync file stays version 1.**
`deliver_llm` is written to the sync file only when `true`
(`FieldSync.omit_false_deliver_llm`, like `item_setting` and `edit_inline`), so
a site that flags nothing exports the file it exported before. The cost is
the usual one (ADR 0047): **a release that predates this column refuses a
file with `"deliver_llm": true`** as an unknown key, with nothing written;
export from the older build or remove the key. Rolling the pin back is
otherwise safe: the column is `NOT NULL DEFAULT false`, which an older
release's inserts satisfy and its reads ignore.

## Rejected

- **Include every text custom field, no flag.** It changes every existing
  artifact, publishes fields editors never meant for crawlers, and forces a
  `format_version` bump.
- **Reuse `searchable`.** It means ranking weight and the search excerpt; the
  two opt-ins would be welded together.
- **Dump the raw item JSON.** Unreadable by an answer engine, and it leaks
  `_id` and `_settings`.
- **Invent a custom `@type` per item type.** schema.org has none;
  `WebPageElement` under `hasPart` is valid.
- **Change the served page's JSON-LD too.** See the accepted divergence above.
