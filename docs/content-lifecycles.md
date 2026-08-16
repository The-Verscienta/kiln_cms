# Content lifecycles

Publishing answers *is this live?*. Lifecycles answer the two questions that
come after: **when does this stop being live**, and **when does someone need to
read it again**.

They are one axis — `health` — computed from four columns, and they are
deliberately *not* part of the state machine. A drug monograph whose annual
review lapsed is still, factually, published; a legal notice past its stated
shelf life is still being served. Making those a `state` would mean the
publishing workflow had to model editorial trust, and the two move
independently.

## The model

Every content type — compiled (`Page`, `Post`, anything from
`mix kiln.gen.content`) and dynamic (the `Entry` tier) — carries:

| Field | Type | Meaning |
|---|---|---|
| `unpublish_at` | timestamp | The embargo end. When it passes, the record expires. |
| `expiry_action` | `:unpublish` \| `:archive` \| `:flag` | What expiry *does*. Default `:unpublish`. |
| `review_after_days` | integer, 1–1095 | Freshness cadence. `nil` (the default) means none. |
| `last_reviewed_at` | timestamp | When a human last attested the content is still correct. |

and computes:

| Calculation | Meaning |
|---|---|
| `effective_review_after_days` | The cadence in force — the record's own, else its type's default. |
| `due_at` | When it next needs re-reading. `NULL` means never. |
| `health` | `:fresh` \| `:due_soon` \| `:due` \| `:overdue` \| `:expired` |

All three are **expression** calculations, computed in Postgres on every read.
That is the design decision, not an implementation detail: a stored `health`
column is wrong for every row between the moment a deadline passes and the
moment a sweep gets to it — which is precisely the window an editor is asking
the question in. Computed in SQL it is right on every read, and it filters and
sorts, so `?filter[health]=overdue` is one `WHERE`, not a table scan in Elixir.

## Expiry: one timestamp, three outcomes

There is no separate `expires_at`. `unpublish_at` is the expiry timestamp, and
`expiry_action` decides what happens when it passes:

* **`:unpublish`** (default) — back to draft, artifacts deleted, `unpublish_at`
  cleared. Recoverable; nothing is lost.
* **`:archive`** — straight to `:archived`, same teardown. For content that
  should leave the working set rather than reappear in the draft list every
  quarter.
* **`:flag`** — *nothing happens to the row*. It stays published and
  `unpublish_at` stays in the past, which is exactly what makes `health` read
  `:expired` from then on. For content that must not silently vanish from a live
  site but does need a human told its stated shelf life has run out.

The first two run as AshOban triggers on the same minute cron as scheduled
publishing, partitioned in SQL by `expiry_action` so neither can pick up the
other's rows — or a `:flag` row, which belongs to neither. `:flag` needs no
worker at all: the signal is the calculation.

## Freshness: the cadence and the attestation

`due_at` is the last attestation plus the cadence — or, for content published
under a cadence but never yet reviewed, the *publish* plus the cadence. Nothing
needs backfilling for that to work; a record with a cadence and no
`last_reviewed_at` starts its clock at `published_at`.

`health` then reads, for published content:

```
expired    unpublish_at has passed
overdue    due_at passed more than 7 days ago
due        due_at passed within the last 7 days
due_soon   due_at falls within the next 7 days
fresh      everything else — including all unpublished content
```

Unpublished content is always `:fresh`. Only live content can mislead a reader.

The seven days is one constant used symmetrically on both sides of the deadline,
rather than two arbitrary numbers.

### Marking reviewed

`mark_reviewed` is its own action — `CMS.mark_page_reviewed!/2`,
`CMS.mark_post_reviewed!/2`, `CMS.mark_entry_reviewed!/2`, or
`ContentTypes.transition(type, "mark_reviewed", record, opts)` for generic
dispatch. It takes no input and stamps `last_reviewed_at` to now.

`last_reviewed_at` is **not** in `default_accept`, so no ordinary save, API
client, or automation can write it. That is the whole point: the column means "a
human said this is still right", and a field an autosave could set would mean
"someone had this open". The action name lands on the PaperTrail version
(`version_action_name: :mark_reviewed`), so *who attested, and when* is
answerable from history rather than inferred.

Version restore never writes any of the four lifecycle columns. They are
reported in the diff — a cadence change is worth seeing — but restoring an old
version must not move a deadline nobody re-set, and for `last_reviewed_at` it
would forge an attestation outright. See `KilnCMS.CMS.VersionFields`.

## Per-type defaults

`TypeDefinition.default_review_after_days` lets an operator say "every clinical
monograph is re-read yearly" once, on the type, instead of on each of four
hundred entries. An entry that sets its own `review_after_days` overrides it;
`nil` on both means the type has no cadence.

It is resolved in `effective_review_after_days`, so raising a type's default
moves every inheriting entry's `due_at` on the next read — no backfill.

**This applies to the dynamic entry tier only.** Compiled types have no
`TypeDefinition` row to inherit from, so for a `Page` or a `Post` the effective
cadence is the per-record one. The alternative considered and rejected was a
site-wide default: a fallback that reaches across every type at once is the
shape that silently re-enables a cadence a team deliberately cleared.

## Reading it

Health is a normal field on the existing reads — there is no lifecycle
endpoint.

```
GET /api/json/pages?filter[health]=overdue&sort=due_at
```

```graphql
{ pages(filter: {health: {eq: OVERDUE}}) { title health dueAt } }
```

```elixir
CMS.Page
|> Ash.Query.filter(health == :overdue)
|> Ash.Query.sort(due_at: :asc)
|> Ash.read!(actor: editor)
```

Health inherits content's own read policy, so an anonymous consumer only ever
computes it over published, unrestricted content — unpublished health never
leaks.

## Authorization

`review_after_days`, `expiry_action` and `unpublish_at` are ordinary accepted
attributes on `:update`, so they are editor+admin writable exactly like
`scheduled_at`. `mark_reviewed` is an update action and follows the same policy.
The expiry workers run under the `AshOban` interaction bypass, as scheduled
publishing does.

## Related

* `docs/content-releases.md` — coordinated multi-item go-live.
* `docs/governance-dashboard.md` — the audit chain over what shipped when.
* `docs/automation.md` — reacting to editorial events.
