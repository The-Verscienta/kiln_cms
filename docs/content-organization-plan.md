# Content organization — assessment & phased plan

**Status:** **proposed** — nothing here is built. This is the design record for
issues [#1593](https://github.com/The-Verscienta/kiln_cms/issues/1593)–[#1597](https://github.com/The-Verscienta/kiln_cms/issues/1597),
written from a read of the current model rather than from a wish list.

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

## 1. What the shape is today

Verified by code inspection, 2026-09-25.

| Concern | Today | Where |
|---|---|---|
| Classification | One mutually-exclusive `belongs_to :category` + a flat many-to-many `Tag` | `content.ex:3472`, `content.ex:3485` |
| Term hierarchy | **None.** The `Taxonomy` macro emits `name`, `slug`, `description` and nothing else | `taxonomy.ex` |
| Vocabularies | `TagGroup` — one optional bucket per tag, with an empty-means-all `content_types` scope | `tag_group.ex` |
| Content hierarchy | **None.** No `parent_id`, no `position` on any content type | `content.ex` |
| The only tree | `MenuItem` (`parent_id` + `position`, cycle-safe walk) | `menu_item.ex`, `menus.ex:196` |
| Relating content — mechanism A | `ContentLink`: a real typed edge table (`kind`, `label`, `metadata`), indexed both directions, **no API routes**, managed only via `manage_relationship` | `content_link.ex` |
| Relating content — mechanism B | `:reference` custom field: a denormalized `%{"id","type","slug","title"}` snapshot in the `custom_fields` jsonb, single-valued | `apply_custom_fields.ex:504` |
| Editor browse | Status + type filter, `ilike(title) or ilike(slug)`, `sort: [updated_at: :desc]`, 50/page | `editor_live.ex:189-194` |
| API browse | `category_id`, `author_id`, `state`, `tag_ids`, `custom_filter` facets over hybrid keyword + semantic search with RRF fusion | `content.ex:1216-1234` |
| Content intelligence | `related_documents`, `near_duplicates`, `suggest_tags`, `content_gaps` — all computed, all org-scoped | `search/related.ex` |
| Where that intelligence surfaces | One document's editor; the analytics page; the public related endpoint | `content_editor_live.ex:4334`, `analytics_live.ex:109`, `related_controller.ex` |
| Media organization | No folders; tags only — **documented as a decision** | `docs/api.md:390` |

The two rows worth reading together are the last four. Kiln computes semantic
neighbourhoods for every block of every document, ranks the existing vocabulary
against a draft, and detects near-duplicates — and then uses all of it to
decorate a single editor screen. Nothing organizes the library.

## 2. Why it reads as old-school

Three things, in order of how loudly they say it:

1. **The Category/Tag split is an inherited distinction, not a modelled one.**
   Two term types that differ only in arity is a WordPress artifact. Drupal
   (vocabularies + hierarchical terms), Craft (category groups) and
   Sanity/Contentful (taxonomy as referenced documents) all converged on one
   term type with a vocabulary above it and a parent beside it.
2. **The console is behind its own API.** An API consumer can facet on author,
   term, state and arbitrary custom fields; an editor gets a status dropdown
   and a substring match on the title. A buyer evaluating Kiln sees the console.
3. **The graph exists but is unreachable.** `ContentLink` is the right table,
   already built and indexed in both directions, and the field type an admin
   actually reaches for writes jsonb snapshots instead.

Notably, none of this is on any existing backlog.
`docs/competitive-gaps-todo.md` and `docs/differentiator-opportunities.md` are
both closed out; content organization was never the subject of a plan. It is a
genuine blank spot rather than a deferred one.

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

## 4. Workstream B — references become edges ([#1594](https://github.com/The-Verscienta/kiln_cms/issues/1594))

> **Proposed decision D20. A content reference is an edge, not a snapshot.**
> The `:reference` field type stores a `ContentLink` row. A cached label may be
> kept for display, but the edge is the source of truth. Multi-valued
> references are multiple rows, ordered by a position on the link.

What the snapshot costs today, all of it present:

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

This wants Workstream C landed first, so the suggestions have a vocabulary
worth aiming at.

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

Either is defensible. The current state is an omission, and an evaluator reads
an omission as an oversight.

---

## 8. Sequencing

| Order | Workstream | Why here |
|---|---|---|
| 1 | **A** — faceted saved views (#1593) | Biggest felt change, no schema risk, reuses facets that already exist |
| 2 | **B** — references as edges (#1594) | Small refactor against a table already built; unlocks backlinks and the graph |
| 3 | **C** — one term vocabulary (#1595) | Schema + deprecation; wants the 1.0 window (below) |
| 4 | **D** — derived organization (#1596) | Best built once C gives it a vocabulary to aim at |
| 5 | **E** — the structure decision (#1597) | Decide explicitly; document either way |

## 9. Timing — C and E are schedule-sensitive

Workstreams C and E change the content contract.
[#1542](https://github.com/The-Verscienta/kiln_cms/issues/1542) (label every
surface), [#1538](https://github.com/The-Verscienta/kiln_cms/issues/1538)
(first deprecations) and
[#1545](https://github.com/The-Verscienta/kiln_cms/issues/1545) (1.0 contract
doc) are actively freezing it. Either they land **before** the freeze with
their deprecations declared in #1538, or they wait for 2.0. They must not get
caught mid-freeze.

A, B and D are additive and can go at any time.

## 10. Honest caveats

- **Workstream D degrades to nothing on a default install.** Semantic search
  ships disabled and the ML stack is opt-in (`KILN_ML=1`), so the differentiator
  is invisible until an operator turns it on. That is a deployment story to
  solve alongside it, not a reason to skip it — but it should not be sold as a
  default-install capability.
- **"Saved views" is a UX pattern, not an architecture.** It will look modern
  and it is genuinely useful, but it does not by itself fix anything in §1.
  Shipping only Workstream A would be treating the symptom.
- **A term hierarchy is not free at read time.** Ancestor rollup means either a
  recursive CTE or a materialized path; pick one deliberately and measure it,
  in the spirit of `docs/performance.md` rather than after a complaint.
