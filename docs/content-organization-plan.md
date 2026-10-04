# Content organization — assessment & phased plan

**Status:** **partly shipped.** Workstreams **A** (#1593, faceted list + saved
views) and **B** (#1594, references as edges) landed in 1.1. **C** (#1595) is on
the **v2.0.0** milestone — collapsing `Category` and `Tag` removes two covered
resources, which the 1.0 contract only allows in a major, so §9's timing
question was answered by deferring rather than by rushing it. **E** (#1597) is
decided (**D21** in §7 — content gets a tree) and **D** (#1596) is scheduled
ahead of C, both on **v1.1.0**; §8 says why that inverts the plan's own
sequencing on purpose.

This is the design record for issues
[#1593](https://github.com/The-Verscienta/kiln_cms/issues/1593)–[#1597](https://github.com/The-Verscienta/kiln_cms/issues/1597),
written from a read of the model as it stood on 2026-09-25. Each workstream
below carries its own status; read the resources for current behaviour and this
for *why*.

**Goal:** move Kiln's *organization* layer — how content relates, how it is
classified, and how an editor finds it again — from the model it inherited
(one category, flat tags, a flat list) to one that matches the rest of the
system.

**The finding in one line:** Kiln's API and its search/AI substrate are already
modern; the editor-facing organization layer is the part that isn't. The gap is
not capability. It is that organization here is **declared by hand, one document
at a time**, while everything needed to **derive** it is already built and
running.

---

## 1. What the shape was on 2026-09-25

Verified by code inspection on that date. **Rows that A or B has since changed
are marked — the rest still hold.** Kept as written rather than rewritten,
because §2's diagnosis and the workstreams argue from it.

| Concern | Today | Where |
|---|---|---|
| Classification | One mutually-exclusive `belongs_to :category` + a flat many-to-many `Tag` | `content.ex:3472`, `content.ex:3485` |
| Term hierarchy | **None.** The `Taxonomy` macro emits `name`, `slug`, `description` and nothing else | `taxonomy.ex` |
| Vocabularies | `TagGroup` — one optional bucket per tag, with an empty-means-all `content_types` scope | `tag_group.ex` |
| Content hierarchy | **None.** No `parent_id`, no `position` on any content type | `content.ex` |
| The only tree | `MenuItem` (`parent_id` + `position`, cycle-safe walk) | `menu_item.ex`, `menus.ex:196` |
| Relating content — mechanism A | `ContentLink`: a real typed edge table (`kind`, `label`, `metadata`), indexed both directions, **no API routes**, managed only via `manage_relationship` — *B: still routeless (it travels as an `included` member), but reference edges are now reconciled by a change, and reads are gated by `Checks.LinkEndsReadable` rather than `always()`* | `content_link.ex` |
| Relating content — mechanism B | `:reference` custom field: a denormalized `%{"id","type","slug","title"}` snapshot in the `custom_fields` jsonb, single-valued — **changed by B**: the snapshot is unchanged, but every live value now *also* carries a `content_links` row (`kind: :reference`, plus `field`/`source_type`/`target_type`), so backlinks exist (integrity only as far as the delete story in §4 goes) | `apply_custom_fields.ex`, `changes/sync_reference_links.ex` |
| Editor browse | Status + type filter, `ilike(title) or ilike(slug)`, `sort: [updated_at: :desc]`, 50/page — **changed by A**: now also author, category, tag, locale, an update-date range, review health and "scheduled", a sort choice, and saved views | `editor_live/filters.ex`, `cms/saved_view.ex` |
| API browse | `category_id`, `author_id`, `state`, `tag_ids`, `custom_filter` facets over hybrid keyword + semantic search with RRF fusion | `content.ex:1216-1234` |
| Content intelligence | `related_documents`, `near_duplicates`, `suggest_tags`, `content_gaps` — all computed, all org-scoped | `search/related.ex` |
| Where that intelligence surfaces | One document's editor; the analytics page; the public related endpoint | `content_editor_live.ex:4334`, `analytics_live.ex:109`, `related_controller.ex` |
| Media organization | No folders; tags only — **documented as a decision** | `docs/api.md:390` |

The two rows worth reading together are the last four. Kiln computes semantic
neighbourhoods for every block of every document, ranks the existing vocabulary
against a draft, and detects near-duplicates — and then uses all of it to
decorate a single editor screen. Nothing organizes the library.

## 2. Why it read as old-school

Three things, in order of how loudly they said it. **Two are now closed** — kept
because they are the argument the workstreams were built from:

1. **The Category/Tag split is an inherited distinction, not a modelled one.**
   Two term types that differ only in arity is a WordPress artifact. Drupal
   (vocabularies + hierarchical terms), Craft (category groups) and
   Sanity/Contentful (taxonomy as referenced documents) all converged on one
   term type with a vocabulary above it and a parent beside it.
2. ~~**The console is behind its own API.**~~ **Closed by A (#1593).** An API
   consumer could facet on author, term, state and arbitrary custom fields
   while an editor got a status dropdown and a substring match on the title.
   The console now facets too — and on more than `:search` does, which is its
   own small hazard (see §3).
3. ~~**The graph exists but is unreachable.**~~ **Closed by B (#1594).**
   `ContentLink` was the right table, already built and indexed in both
   directions, while the field type an admin actually reaches wrote jsonb
   snapshots instead. Reference values now write edges as well, and the editor
   lists "Linked from".

Notably, none of this was on any existing backlog when this was written.
`docs/competitive-gaps-todo.md` and `docs/differentiator-opportunities.md` were
both closed out; content organization had never been the subject of a plan. It
was a genuine blank spot rather than a deferred one — which is the reason this
document exists.

---

## 3. Workstream A — faceted, saved views ([#1593](https://github.com/The-Verscienta/kiln_cms/issues/1593))

**The highest felt-change-per-risk item in this plan.** No content-schema
change at all.

Point the console at the faceting the `:search` action already generates:
facet chips for term / author / locale / date range, a sort choice, a group-by
axis, and **saved views** — the filter state is already URL-encoded for
shareable links, so promoting it to a named, savable row (private per-user,
plus org-wide views an admin pins) is a small resource and a picker. Per-type
columns driven by `FieldDefinition` complete it; [#1585](https://github.com/The-Verscienta/kiln_cms/issues/1585)
is the search half of the same gap.

**The one real obstacle:** `:search` declares `argument :query, :string,
allow_nil?: false`, so it cannot back an empty-query faceted browse as written.
Either relax that on a console-scoped read or add a sibling `:browse` action
that shares the same `facet_args`/`facet_clauses` closures. Do **not** fork the
facet list — that drift is exactly what `KilnCMS.CMS.Taxonomy` was written to
stop, and it had already happened once there (`TagGroup` shipped without a
`:search` action and was unfindable in `/search` with nothing failing).

**Status (1.1).** The facets, the sort choice and saved views shipped
([#1593](https://github.com/The-Verscienta/kiln_cms/issues/1593)): author,
category, tag, locale, an update-date range, review health and "scheduled",
all in the URL; private views plus admin-shared ones (`KilnCMS.CMS.SavedView`).
The list reads each type's primary `:read` with the facets as filters rather
than a `:browse` sibling of `:search`, so the obstacle above did not arise —
but it does mean the console's facets (`KilnCMSWeb.EditorLive.Filters`) are a
second list beside `:search`'s `facet_args`, a superset of it. A facet added to
one should be considered for the other. Still open: a group-by axis, and
per-type columns from `FieldDefinition`.

## 4. Workstream B — references become edges ([#1594](https://github.com/The-Verscienta/kiln_cms/issues/1594))

> **Proposed decision D20 — adopted in capability, not in form.** *A content
> reference is an edge, not a snapshot: the `:reference` field type stores a
> `ContentLink` row, a cached label may be kept for display, but the edge is the
> source of truth.*
>
> 1.1 added the edge **beside** the snapshot instead of replacing it, because
> 1.0's overlay contract had since made `custom_fields` and its documented
> shapes a covered surface. So the snapshot remains the value and the edge is
> not the source of truth — the capability D20 wanted (backlinks, integrity, a
> visible graph) arrived without the swap it asked for. Left recorded in its
> original form rather than rewritten to match, so the constraint that changed
> the shape stays visible. See *Built in 1.1* below for what actually landed,
> including a delete story narrower than "the edge is authoritative" implies.

What the snapshot cost, which is the case the edge was added to answer:

- **No reverse lookup** — "what links here" needs a jsonb scan across every
  content table.
- **No referential integrity** — purge the target and the snapshot survives,
  pointing at nothing.
- **Stale display data**, acknowledged in the code itself: slug and title "may
  go stale until the next save."
- **Single-valued** — `extract_id/1` takes one id; there is no array reference.
- **Invisible to the graph** — reference-aware invalidation (D13) cannot see
  these edges.

The migration is a backfill plus a one-release jsonb read-fallback, retired
under the [#1538](https://github.com/The-Verscienta/kiln_cms/issues/1538)
deprecation window. The delete story needs an explicit answer — block a purge
with inbound edges, or null the edge and flag the referrer; today neither
happens.

### Built in 1.1 — additively ([#1594](https://github.com/The-Verscienta/kiln_cms/issues/1594))

1.0's overlay contract made `custom_fields` and its documented shapes a
covered surface, so 1.1 adds the edge **beside** the snapshot rather than in
place of it. What landed:

- **Dual-write.** Every live `:reference` value has a `ContentLink` row:
  `kind: :reference`, `field` the custom field's name, `position`, and
  `source_type` / `target_type` (new nullable columns). The snapshot is
  written exactly as before and keeps its meaning. Edges are reconciled from
  the *stored* value after any write that moved it
  (`Changes.SyncReferenceLinks` → `KilnCMS.CMS.ContentLinks`), so the two
  cannot disagree; renaming or deleting a field definition moves or deletes
  its edges with its values. The unique identity gained `field` (NULLs not
  distinct), so one record may reference the same target from two fields.
- **Backfill.** A data migration (plain SQL, idempotent) writes the edges for
  values stored before 1.1; `mix kiln.links.backfill` re-runs it.
- **Live only.** A published record's working copy holds draft custom fields
  in `working_fields`; a held reference has no edge until *Publish changes*.
  What links here is what a reader could follow.
- **Readability follows both ends.** `ContentLink` was world-readable, which
  already let a published page's `incoming_links` name the drafts linking to
  it. An edge is now readable only by someone who may read its source *and*
  its target (`Checks.LinkEndsReadable`, delegating to the content read
  policy); editors see every edge of their site.
- **Not related content.** `related_<type>s` is a many-to-many through the
  same table with no `kind` filter; reference edges are kept out of it (and
  out of its managed unrelate), so its meaning is unchanged.
- **Uses.** *Linked from* in the editor, with an unpublish that asks first
  when anything links here; *Broken references* on a referrer whose target
  was trashed or purged; `incoming_links` / `content_links` on the read API
  carry the edges, with the three new attributes.
- **Delete story.** Neither blocking a purge nor nulling: a purge removes the
  purged record's *outgoing* edges, and edges pointing *at* it stay — they
  are what the referrer's editor reports as broken, and they go when the
  referrer is next saved with the field cleared or re-pointed. Trash keeps
  every edge, so a restore needs nothing.

**Why edges do not contradict D3.** D3 keeps a document's *own* structure —
its blocks — embedded, so a document versions and restores atomically.
References are relations *between* documents: neither side owns the other,
and the question asked of them ("what links here") runs across every
document, which is exactly what D3 says an embedded tree should not be made
to answer by scanning. The snapshot stays embedded and versioned with its
document; the edge is a derived index of it, like the search document D3
names for cross-block queries.

**Not in 1.1.** Array references (one field, many targets) — the edge model
is ready (`position`), the field type and its editor input are not. And the
snapshot is **not deprecated**: removing or reshaping it changes a covered
surface, so it waits for 2.0 and goes through the deprecation path then
(`docs/overlay-contract.md`, "When a covered surface must change") — a
replacement documented beside it, a `### Deprecated` entry, and a warning
where the stored rows are read. The likely 2.0 shape keeps `id` and `type` in
the value and resolves `slug` / `title` from the edge's target at delivery.

## 5. Workstream C — one hierarchical term vocabulary ([#1595](https://github.com/The-Verscienta/kiln_cms/issues/1595))

> **Proposed decision D19. Taxonomy is one hierarchical term vocabulary.**
> `Category` and `Tag` collapse into one `Term` carrying `parent_id` +
> `position`. `TagGroup` is promoted to a `Vocabulary`, which declares whether
> it is single- or multi-valued per content type — which is where the old
> Category/Tag distinction actually belongs.

Cheaper than it looks, for four reasons that already hold:

- `Tagging` is **polymorphic on `subject_id`** with no type discriminator, so
  multi-valued terms need no join-table work for any content type.
- `TagGroup` is already most of a vocabulary — `position`, `content_types`,
  picker sectioning.
- `KilnCMS.CMS.Taxonomy` is one macro; `parent_id` added there lands on every
  taxonomy resource at once, with the policy stack, multitenancy and slug
  identity already shared.
- Tag name vectors are already persisted (`KilnCMS.SearchIndex`, #1085), so
  alias suggestion and near-duplicate term detection are nearly free.

Also in scope: term aliases/synonyms, and merge/move as first-class verbs in
`/editor/taxonomy`.

## 6. Workstream D — derived organization ([#1596](https://github.com/The-Verscienta/kiln_cms/issues/1596))

The differentiator, and the reason this plan is worth more than parity work.

Lift `KilnCMS.Search.Related` from a per-document decoration to a library-level
organizing layer: semantic clusters as a browse axis, a bulk auto-tagging
review surface (`suggest_tags/2` already constrains itself to *existing* terms
— that constraint is the whole point and it is already there), an
under-organized queue, and a taxonomy-health view for single-use terms,
near-duplicate terms and orphans with no inbound links.

Two constraints that are not optional:

- **No-op with empty results when semantic search is disabled.** That is the
  existing contract across the search stack, and semantic is off by default.
- **Budget accounting is part of the design.** `near_duplicates/2` and
  `suggest_tags/2` fall onto the on-demand inference path for unpublished
  documents — one inference per block — routed through `KilnCMS.LLM.Budget`
  (#1076). A bulk surface multiplies that by the selection size, and
  `docs/automation.md` already documents a bulk move exhausting the embedding
  reserve.

**Scheduled for v1.1.0, ahead of C.** This originally wanted Workstream C
landed first, so the suggestions would have a vocabulary worth aiming at. C is
now a v2.0.0 item, and waiting for it would park the one differentiator in this
plan behind the one breaking change in it — so D is built against today's
`Category`/`Tag` and migrated with C when C happens.

The rework that buys is accepted rather than overlooked: the taxonomy-health
view and the bulk auto-tagging surface both target a vocabulary C will replace.
Keep the term-facing parts thin for that reason — prefer one narrow helper over
scattering `Tag`/`Category` reads across the new surfaces, so the 2.0 migration
has a single seam instead of many.

## 7. Workstream E — the structure decision ([#1597](https://github.com/The-Verscienta/kiln_cms/issues/1597))

A decision, not a feature. Content is flat; site structure lives in a
hand-curated nav menu disconnected from the content it points at, so
reorganizing a section means doing it twice with nothing keeping the two
honest.

**Option A — content gets a tree:** `parent_id` + `position` with a
materialized path, a tree view, drag-to-reorder, and a menu builder that
*derives* from structure instead of duplicating it. Costs: path-scoped slug
uniqueness, redirects on move (`Redirect` already handles slug changes), and
cycle safety (copy `Menus.rooted?/3`). Keep it a distinct axis from Workstream
C — a term hierarchy and a content tree are different things and neither should
impersonate the other.

**Option B — commit to "URL is a slug, structure is a menu":** write it down
the way D3, D4 and D17 are written down, then make the menu builder genuinely
good at the job — bulk operations, orphan detection, a structure-shaped view
over the flat list. The media library has already made a consistent call in
this direction, and the difference is that *that* one is documented.

> **Decision D21. Content gets a tree; the URL shape it already has carries it.**
> `parent_id` + `position` on content, cycle-safe. A path derives from the
> ancestor chain through the **existing** `path_alias` mechanism (#485) plus one
> new `alias_pattern` token — not through new URL resolution. **Default
> resolution does not change**: a record with no parent, or no ancestor-derived
> alias, resolves exactly as it does today. The content tree stays a distinct
> axis from C's term hierarchy. Milestone **v1.1.0**.

**Option B was disqualified by the code, not by taste.** B asks us to write down
"URL is a slug, structure is a menu" — and that is already false. `path_alias`
ships and is served: any record can live at a multi-segment path, auto-filled
from `alias_pattern`, validated by `Validations.PathAliasValid`, separately
indexed, and `Changes.RecordSlugRedirect` already fires when it is **added,
changed or removed**, not only on a slug rename. Committing to B would record a
rule the delivery layer contradicts, which is the drift this document exists to
stop. The media-library precedent does not transfer: that call is documented
*and* the code agrees with it.

**A is additive, which is what makes it a 1.1 item** rather than a 2.0 one. This
corrects §9's earlier reading, which assumed a tree needs new URL resolution:

| Piece | Status |
|---|---|
| `parent_id` + `position` | new nullable attributes — additive |
| Resolving a nested path | **already shipped** (`path_alias`) |
| Deriving it from the ancestor chain | one new `alias_pattern` token — additive |
| 301s on a move | **already shipped**; `Redirect` targets the record, not a frozen path, so repeated moves never chain |
| Cycle safety | copy `Menus.rooted?/3` |

**Out of scope for 1.1, deliberately:** menus derived from the tree (ship the
tree plus orphan detection first, or we trade one duplication for a migration in
the same release), and any change to default URL resolution — that would be a
2.0 conversation and D21 does not authorise it.

**The cost to measure rather than assume:** a subtree move re-derives every
descendant's alias and writes a redirect per descendant. A deep section is N
alias writes plus N redirect rows, and in one transaction that is the next
`Repo.transaction`-timeout story. It needs a bound, and past some size a
background job. §10's note applies too — ancestor rollup means choosing
deliberately between a recursive CTE and a materialized path, and measuring it.

---

## 8. Sequencing

| Order | Workstream | Why here | State |
|---|---|---|---|
| 1 | **A** — faceted saved views (#1593) | Biggest felt change, no schema risk, reuses facets that already exist | **shipped 1.1** |
| 2 | **B** — references as edges (#1594) | Small refactor against a table already built; unlocks backlinks and the graph | **shipped 1.1** |
| 3 | **C** — one term vocabulary (#1595) | Schema + deprecation; wants the 1.0 window (below) | **deferred to v2.0.0** |
| 4 | **D** — derived organization (#1596) | Originally: once C gives it a vocabulary to aim at. **Reversed** — see below | **v1.1.0** |
| 5 | **E** — the structure decision (#1597) | Decide explicitly; document either way | **decided (D21), v1.1.0** |

The order held for the two that shipped, and in the direction the table
predicted: A was the visible change and carried no schema risk, B was small
because the table was already there.

**D's sequencing problem is resolved: it goes before C, not after.** D was
placed after C so its suggestions would have a vocabulary worth aiming at. Once
C became a v2.0.0 item that ordering would have parked the plan's one
differentiator behind its one breaking change, so D is on **v1.1.0**, built
against today's `Category`/`Tag`, and migrated with C later. The second pass
costs less than a release of delay (see §6).

That leaves the original table's order intact only for A and B. The live order
is: A and B shipped, **D and E in 1.1**, **C in 2.0** — which inverts the one
dependency this plan originally asserted, deliberately.

## 9. Timing — C and E were schedule-sensitive

**Resolved, the second way.** Workstreams C and E change the content contract,
and [#1542](https://github.com/The-Verscienta/kiln_cms/issues/1542) (label every
surface), [#1538](https://github.com/The-Verscienta/kiln_cms/issues/1538) (first
deprecations) and
[#1545](https://github.com/The-Verscienta/kiln_cms/issues/1545) (the 1.0
contract doc) were freezing it while this was written. The call was: land before
the freeze with deprecations declared, or wait for 2.0 — but not get caught
mid-freeze.

1.0 shipped on 2026-10-02 and **C waited**: #1595 is on the **v2.0.0**
milestone, because replacing `Category` and `Tag` with one vocabulary removes
two covered resources, which the 1.0 overlay contract permits only in a major,
with a deprecation path through 1.x first. That deprecation path is the next
thing C needs, and it belongs in a 1.x release rather than in the 2.0 work.

**E is resolved** — as D21 in §7, Option A, milestone v1.1.0. The worry recorded
here was that 1.0 had frozen the surface E would change, because a path in the
URL is not additive. That premise was wrong: `path_alias` already resolves
multi-segment paths and already records its own redirects, so the tree rides
shipped machinery and stays additive. Worth noting as the cheaper lesson —
checking what delivery already does would have answered this before it was
filed as an open question.

A, B and D are additive and can go at any time — which is what lets D precede C
rather than follow it.

## 10. Honest caveats

- **Workstream D degrades to nothing on a default install.** Semantic search
  ships disabled and the ML stack is opt-in (`KILN_ML=1`), so the differentiator
  is invisible until an operator turns it on. That is a deployment story to
  solve alongside it, not a reason to skip it — but it should not be sold as a
  default-install capability.
- **"Saved views" is a UX pattern, not an architecture.** It looks modern and
  is genuinely useful, but it did not by itself fix anything in §1 — and with A
  and B both shipped, the §1 rows it left untouched are still the honest list:
  no term hierarchy, no content hierarchy, one mutually-exclusive category.
- **A term hierarchy is not free at read time.** Ancestor rollup means either a
  recursive CTE or a materialized path; pick one deliberately and measure it,
  in the spirit of `docs/performance.md` rather than after a complaint.
