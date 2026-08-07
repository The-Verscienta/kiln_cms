# Navigation menus

Editor-managed site navigation (#466). A **menu** is a named, ordered tree of
items — "Main navigation", "Footer" — addressed by a stable `key` so a front end
asks for `main` without knowing an id.

Before this, Kiln had no navigation resource at all: categories are flat, and
every headless front end had to hard-code its nav.

## Modelling

| | |
|---|---|
| `KilnCMS.CMS.Menu` | `key`, `name`, `locale`, `description`. Unique on `(key, locale)` per site. |
| `KilnCMS.CMS.MenuItem` | `label`, `position`, `parent_id` (the tree), a destination, `open_in_new_tab`, `visible`. |
| `KilnCMS.CMS.Menus` | Delivery-side resolution: the flat rows folded into a tree with live URLs. |

Menus are structure, not content: no workflow, no version history, no
soft-delete — the same lightweight treatment `Category` and `TagGroup` get.
Editors manage them at **`/editor/menus`**.

## Destinations

`link_type` decides what an item points at:

* **`:content`** — a *reference* to a content record (`target_type` +
  `target_id`, the same currency `Redirect` and `ContentLink` speak). The URL is
  computed at read time from the record's **current** published path, so
  renaming a slug moves the navigation with it and never leaves a dead link.
  This is the whole reason a reference is stored rather than a path.
* **`:url`** — an external or hand-written destination. Passed through
  `KilnCMS.HTMLSanitizer.safe_href/1` on write, so a `javascript:` trap can't be
  stored, let alone served to a front end that trusts the API.
* **`:none`** — a heading with no link (a section label in a mega-menu).

Switching `link_type` clears the destination the item no longer uses: an item
that kept both would carry two answers, and a consumer picking the "wrong" one
would follow a link the editor believes they deleted.

## The tree

`parent_id` nests, `position` orders siblings. Two guards are enforced at write
time, on the writes that actually *move* an item:

* depth stops at `KilnCMS.CMS.MenuItem.max_depth/0` (3 — section → group →
  link; deeper than that is a sitemap, not a menu), **counting the subtree a
  move carries** — checking only the moved node would land its leaves deeper
  than the cap and then leave them unmovable;
* an item can be neither its own parent nor its own descendant, and can't be
  parented into a different menu.

Both are skipped when `parent_id` isn't changing. A depth check that fired on
every write would freeze a too-deep row: you couldn't rename it, and you
couldn't outdent it either, because outdenting is itself a write.

The *read* path is safe regardless of what is stored. Two editors re-parenting
concurrently can commit a cycle (each validates against pre-commit state), but
the walk descends only from the roots and emits each node under its single
parent — so a cycle's members become unreachable and vanish from the served
tree rather than looping. That is silent data loss, which is what the write-time
guards are actually protecting against.

In the builder, drag reorders within a level and **indent/outdent** changes
depth. Depth is buttons rather than drag on purpose: dropping *into* a sibling
is a small target, ambiguous at the "after this / inside this" boundary, and
unreachable from a keyboard — and this tree is the site's navigation.

## Localization

A menu is **per locale**, exactly like content: variants share a `key` and
differ by `locale`, so `/api/menus/main?locale=fr` returns French labels *and*
French destinations.

This is deliberately the shape of the one-record-per-locale content model rather
than a per-item translations map. Labels, ordering, and *which items exist* all
differ between locales in practice ("Impressum" has no English sibling), and a
map can only translate the first of those.

A missing locale variant is a **miss, not a fallback**: silently serving English
navigation on a French page is a worse answer than serving none, and only the
caller knows which it prefers.

## Delivery

```
GET /api/menus                 → every menu's key/name/locale
GET /api/menus/:key            → one resolved tree (the request's locale)
GET /api/menus/:key?locale=fr  → the French variant
```

```json
{
  "key": "main",
  "name": "Main navigation",
  "locale": "en",
  "items": [
    {
      "id": "…",
      "label": "Products",
      "url": null,
      "link_type": "none",
      "open_in_new_tab": false,
      "children": [
        {"id": "…", "label": "Kilns", "url": "/kilns", "link_type": "content",
         "open_in_new_tab": false, "children": []}
      ]
    }
  ]
}
```

Two rules apply to every resolved tree, and they are the reason this endpoint
exists rather than a raw resource read:

* a `:content` item's `url` is the target's **current published path** — its
  `path_alias` when set, else `/<prefix>/<slug>` — so navigation never links to
  a URL that would immediately 301;
* an item whose target isn't published, or that an editor has switched off, is
  **omitted along with its children**. A dropped section takes its links with it
  rather than promoting them to the top level, which is what "omit unpublished"
  has to mean visually.

There is a GraphQL twin with the same rules:

```graphql
{ menu(key: "main", locale: "fr") { name items { label url children { label url } } } }
```

It returns `null` for a locale the menu has no variant in, matching the REST
404.

Responses are `public, max-age=60` with no `Vary`: the locale is part of the URL
(`?locale=` or a `/fr/…` prefix), never a header or a cookie, so the URL is the
whole cache key.

The stored `Menu`/`MenuItem` rows are deliberately **not** on the auto JSON:API
or GraphQL surfaces. They carry references rather than URLs — and, more to the
point, they carry items an editor has hidden and items pointing at unpublished
content, which is exactly what the two rules above exist to withhold. Serving
them raw would publish the label and target id of an unannounced page to any
anonymous caller.

## Authorization

Menus are world-**readable**: navigation is rendered on every public page, and a
headless front end fetches it anonymously. What an item *points at* is still
gated by the resolution rules above.

Writes follow the taxonomy pattern: editors create and edit menus and items,
deleting a **menu** is admin-only (it takes every item with it), and a
read-scoped API key can never write.
