# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

<a id="the-content-list-filters-and-saves-views"></a>

- **The content list filters by author, category, tag, language, update date
  and review health, sorts by update, publish date or title, and saves a
  filter as a named view.**
  The console's list offered status, type and a title search, sorted by last
  update, while the search API already faceted on author, category and tags
  ([content organization plan](../content-organization-plan.md), §3). The list
  now filters on all of those plus language, an update-date range, review
  health ("review due", "due soon", "expired") and "scheduled to publish", and
  sorts by last update, last publish or title. The everyday facets sit beside
  the search box; the rest open from **More filters**, and each active facet
  shows as a chip with its own remove button.

  All of it stays in the URL, as status and search already did: a link, a
  refresh and the back button keep the filter, and a value that cannot be valid
  (a deleted category, a malformed date) reads as absent rather than failing.

  **Views.** Five built-in views — *All content*, *My drafts*, *Needs review*,
  *Scheduled* and *Review due* — sit above the list, and **Save view** stores
  the current filter under a name (`KilnCMS.CMS.SavedView`). A saved view is
  private to its owner; an admin can share one with every editor on the site,
  and only an admin can rename or delete a shared view. Views are per site.

  **Speed.** Each page of the list used to sort the whole site's content to
  keep 51 rows (about 7 ms at 30,000 posts, growing linearly). Three new
  indexes per content table, on `(org_id, updated_at, id)`, `(org_id, title,
  id)` and `(org_id, published_at DESC NULLS LAST, id DESC)`, serve the three
  orders directly (0.03 ms on the same data), and paging continues from a
  keyset per content type, so *Load more* never repeats or skips a row under
  any sort. The indexes are built `CONCURRENTLY`, so a large table keeps
  taking writes while the migration runs. An overlay's own content types get
  them from `mix ash.codegen` in the overlay, as with any index the content
  macro adds; until then their rows list exactly as before, only sorted in
  memory.
  ([#1854](https://github.com/The-Verscienta/kiln_cms/pull/1854))

## Fixed

<a id="concluding-an-experiment-now-refuses-a-winner-that-is-not-one-of-its-own"></a>

- **Concluding an experiment now refuses a winner that is not one of its own
  variants.**
  `:conclude` took `winner_variant_id` as a `:uuid` argument and wrote it
  straight to the attribute, so the type was the only gate: a non-uuid was
  refused and any well-formed uuid was accepted and stored — one belonging to no
  variant at all, or to a variant of a different experiment on the same site.

  Nothing mis-read it. `Promotion` looks the winner up among *this* experiment's
  arms and answers `:winner_missing`, so no wrong copy was ever written into a
  document. The cost was the row, and the row could not be corrected:
  `winner_variant_id` is `writable? false`, the state machine has no
  `concluded → concluded` transition, and `:update` refuses anything but a
  draft — so all three remedies were shut and nothing short of SQL took the bad
  id back out.

  What it left behind contradicted itself. The Promote button renders on
  `state == :concluded and winner_variant_id`, so it was offered and could never
  succeed, while `winner?/2` matched no row so no `winner` badge showed. The
  page said both "there is a winner to promote" and "no arm won", and the only
  way out was to archive the experiment. The dangling id also shipped in the
  `experiment.concluded` payload, to webhook endpoints, automation rules and
  federation, where nothing could tell it from a real one.

  Ordinary use never produced one. `mix kiln.experiment conclude --winner NAME`
  resolves the name among the experiment's variants and raises on one that is
  not there, and the editor's `<select>` is built from `@experiment.variants` —
  whose options cannot even go stale, because `RefuseWhenRunning` freezes the
  arms for as long as the conclude form is on screen. The action was the only
  layer without the check, which is the layer a crafted LiveView event and any
  other caller of the `conclude_experiment/3` code interface reach.

  `Validations.WinnerIsAVariant` now refuses it, on `field: :winner_variant_id`.
  Concluding with no winner is unchanged — it is a real choice, and the common
  outcome for a test that found no difference. The check reads the arms as the
  system actor with `authorize_with: :error` so it fails closed: a refused read
  answers `[]` under a filter policy, which would otherwise read as "not an arm"
  and refuse a perfectly good winner.
  ([#1851](https://github.com/The-Verscienta/kiln_cms/pull/1851))

