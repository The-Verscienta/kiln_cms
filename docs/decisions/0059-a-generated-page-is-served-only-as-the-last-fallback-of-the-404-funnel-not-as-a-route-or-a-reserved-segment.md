# 0059. A generated page is served only as the last fallback of the 404 funnel, not as a route or a reserved segment

- **Status** — accepted (2026-11-13), recorded after the fact. The rule
  shipped with the event index in 0.5.0
  ([#1070](https://github.com/The-Verscienta/kiln_cms/pull/1070)), and two
  later pages followed it, both in 1.9.0: the standalone form page
  ([#2341](https://github.com/The-Verscienta/kiln_cms/pull/2341)) and the
  stock `/home` ([#2702](https://github.com/The-Verscienta/kiln_cms/pull/2702)).
  Until now it was written down only in comments in
  `KilnCMSWeb.ContentController`. The issue that asked for this record names
  two users; there are three.
- **References** — [#2340](https://github.com/The-Verscienta/kiln_cms/issues/2340),
  which asked for this record;
  [#766](https://github.com/The-Verscienta/kiln_cms/issues/766) and #1070
  (the event index);
  [#2138](https://github.com/The-Verscienta/kiln_cms/issues/2138) and #2341
  (the form page), whose planning notes record the route that was rejected;
  [#2636](https://github.com/The-Verscienta/kiln_cms/issues/2636) and #2702
  (the stock `/home`);
  [#1783](https://github.com/The-Verscienta/kiln_cms/issues/1783), which
  pointed the forms list at `/forms/<slug>/embed` because nothing answered at
  `/forms/<slug>`, and which #2341 superseded;
  [#2143](https://github.com/The-Verscienta/kiln_cms/issues/2143) and
  [#2374](https://github.com/The-Verscienta/kiln_cms/issues/2374) for what
  reserving a segment later costs;
  [#2898](https://github.com/The-Verscienta/kiln_cms/issues/2898) for the
  routes the reserved list misses;
  [ADR 0009](0009-events-are-a-shape-content-can-take-not-a-resource-of-their-own.md)
  for the event index itself.
- **Changelog** — [0.5.0](../changelog/v0.5.0.md#events-whats-on-soonest-first)
  (Added, the event index);
  [1.9.0](../changelog/v1.9.0.md#public-form-page) (Fixed, the form page);
  [1.9.0](../changelog/v1.9.0.md#brand-link-keeps-locale) (Fixed, the stock
  `/home`).

## The problem

A *generated page* is one Kiln builds from something other than a content
record at that address: a type's schedule, a form, the stock front page
template. Each one wants an address in the space that content already owns,
`/<slug>` and `/<plural>/<slug>`, and that space is not empty. A site may
already answer there with a page, an entry of its own content type, a path
alias (which may be a single segment, such as `/gigs`) or a redirect.

The router offers two ways to give a generated page an address, and both take
it from whatever answered there before:

- **A route** declared ahead of the delivery catch-alls (`/:type/:slug`,
  `/:slug`, `/*path` in `KilnCMSWeb.Router`) wins outright. Route order is
  invisible from the content side, so a record that answered at the address
  yesterday silently stops answering.
- **A reserved segment** (`@reserved_path_segments` in
  `KilnCMS.CMS.ContentTypes`) makes the validators refuse new slugs, aliases
  and type segments that collide. It does nothing for records already stored,
  and it blocks every later update of a dynamic type that already uses the
  segment: `Validations.AvailableTypeName` checks the type's `path_segment`
  on every write, not only when it changes.

## Decision

**A generated page is the last thing the 404 funnel tries.** It is passed as
the `fallback` argument of `ContentController.follow_redirect_or_404/4` and
runs only after everything that could answer at the address has declined. A
generated page may turn a 404 into a page. It may never take an address from
something that answers there.

The order, as the code runs it:

1. **Content.** The route's own action reads the record: `show_page/2` for
   `/<slug>`, `show_content/2` for `/<plural>/<slug>`. Only on a miss does it
   enter the funnel.
2. **Path alias** (`serve_alias/2`): a published record whose `path_alias` is
   the path, then a passphrase-locked one (`lock_alias/5`), then an
   audience-gated one's teaser (`teaser_alias/4`).
3. **Redirect** (`KilnCMS.CMS.Redirects.resolve/3`), a 301.
4. **Lock page** for a locked record of the route's type at that slug
   (`serve_lock/3`).
5. **Teaser** for a gated record of the route's type at that slug
   (`serve_teaser/3`).
6. **The generated page** (`fallback`).
7. **404** (`not_found/2`), which records the missed path. A generated page
   that declines, such as an inactive form, falls through to it, so its miss
   is recorded like any other.

The order is stated once, in `follow_redirect_or_404/4`, not inferred from
which branch called what.

### The three users

| Page | Address | Caller | Hook | Shipped |
| --- | --- | --- | --- | --- |
| Event index ("what's on") | `/<plural>` | `show_page/2` | `event_index/3` | 0.5.0, #766 |
| Stock front page | `/home`, in practice `/<locale>/home` | `show_page/2` | `stock_home/3` | 1.9.0, #2636 |
| Standalone form page | `/forms/<slug>` | `show_content/2` | `form_page/3` | 1.9.0, #2138 |

`show_page/2` passes `event_index(...) || stock_home(...)` as one fallback.
The two cannot both match unless `home` is an event-shaped type's segment
(nothing reserves `home`); then the event index takes `/home`, a page slugged
`home` is refused, and only an alias or a redirect can replace it. `show_post/2` (`/blog/<slug>`) and `fallback/2` (three or more
segments) pass none, so no generated page lives under `/blog/` or at a deep
path today.

### Replacing a generated page

An operator who wants something else at a generated page's address puts a
**path alias or a redirect** there, and it wins. Content wins too, where
content can exist at that address:

- `/<plural>`, the type's path segment: a page with that slug is refused, since
  `KilnCMS.CMS.Slugs.taken_root_segments/1` holds every type's path segment.
  An alias or a redirect is the way.
- `/home`: a published Home page (slug `home`) is the intended replacement.
  An alias or a redirect also wins.
- `/forms/<slug>`: a site's own content type whose path segment is `forms`
  keeps its entries, and an alias or a redirect also wins. `forms` is not
  reserved, so `Validations.PathAliasValid` accepts an alias under it.

### What the tests cover

The funnel order applies to all three, but only these cases are tested:

| Page | What is tested to win over it | Test |
| --- | --- | --- |
| Event index | a redirect; a page at the same slug (seeded, since the validator refuses it) | `test/kiln_cms_web/controllers/event_index_test.exs` |
| Form page | a path alias; a redirect; an entry of a site type at `forms` | `test/kiln_cms_web/controllers/form_page_test.exs` |
| Stock `/home` | a published Home page | `test/kiln_cms_web/chrome_locale_test.exs` |

No test covers a path alias over the event index, an alias or redirect over
`/home`, or a lock page or teaser over any of the three.

### Other surfaces

- **`GET /api/resolve`** knows content, path aliases and redirects, and
  answers `not_found` for a generated page's address. That fits the rule: a
  generated page is what delivery does when nothing is there, and a headless
  front end decides for itself what to show at such an address.
- **Firing and the static export** produce none of the three. Firing compiles
  one published document at a time, and `KilnCMS.Firing.StaticExport` copies
  those documents' fired artifacts. `sitemap.xml` lists published records
  only, so it lists none of them either.

## When a dedicated route is acceptable instead

A built-in page may have a route of its own when content cannot own its
address, or when the route itself checks content first:

- **Content cannot own the address.** The path is under a namespace the
  router owns and has reserved (`/api/`, `/editor/`, `/auth/`), or it is a
  two-segment `/<plural>/<file>` whose last segment cannot be a slug or an
  alias (both formats allow no dot), so no record can be stored there (`/<plural>/index.json`, the event index's JSON
  twin; `/<plural>/calendar.ics`; `/<plural>/feed.xml`).
- **The route checks content first.** `ContentController.home/2` answers `/`
  with the published Home page when the site has one, through `show_page/2`,
  and only otherwise with the stock template.

A route that takes a whole first segment (`/blog`, `/search`, `/membership`,
`/access-denied`) must join `@reserved_path_segments` in the same change, so
`Slugs.taken_root_segments/1` and `Validations.PathAliasValid` refuse new
collisions. The change also needs an upgrade note telling operators to run
`mix kiln.reserved_paths` (`KilnCMS.CMS.ReservedPathAudit`), because reserving
a segment later shadows records stored before it. That is what happened when
`access-denied` was added in #2143; #2374 asked for an audit of what it shadowed, and #2666 shipped it (`mix kiln.reserved_paths`).

The cost of this path is that the list is kept in sync with the router by
hand. #2898 found single-segment routes ahead of `/:slug` that are not in it
(`developers`, `actor`, `ap`, `ready`, `sign-out` and others): a page with such a slug is
accepted and can never be reached. A plugin's pages (`Kiln.Plugins.public_routes/0`
and `plug_routes/0`) are declared ahead of the catch-alls the same way and are
not in the list either. Until a test ties the two together, a new route of
this kind shadows silently.

## Rejected

- **A `/forms/:slug` route with `forms` reserved.** This was #2341's first
  plan. The route would have taken `/forms/*` from any site serving it
  through a content type, a path alias or a redirect. The reservation would
  then have refused every update to a dynamic type whose path segment is
  `forms`.
- **A `/:plural` route for the event index.** `/:slug` already owns single
  segments. A second route competing for them would decide the page-versus-
  index precedence in the router, where nobody reading the delivery code can
  see it. Which types are event-shaped is also data (a `datetime_range` field),
  so it cannot be compiled into literal routes.
- **Ordering each generated page in its own caller.** Each caller would need
  to repeat the alias, redirect, lock and teaser checks in the same order.
  Putting the slot in the funnel states that order once.

## Consequences

- **A generated page can lose its address to anything added later,** by
  design. `docs/forms.md` tells an editor what to do when a different page
  answers at a form's address.
- **A generated page pays for the whole miss path.** Every request runs the
  content lookup and the alias, redirect, lock and teaser lookups first, and
  none of the three pages is kept in the server's response cache.
- **The next generated page goes in the same slot.** It is passed as (part
  of) a `fallback`, it returns `nil` when it does not apply, and the record's
  table above gains a row. A page at a deep path or under `/blog/` would first
  need `fallback/2` or `show_post/2` to pass one.

## Not decided here

- The fix for #2898, which keeps the reserved list and the router in sync.
- Tests for the precedence cases listed as untested above.
