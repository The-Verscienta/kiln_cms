defmodule KilnCMS.CMS.ContentTree do
  @moduledoc """
  Where a document *lives* — the content tree (#1597, decision **D21**).

  Every content type gains `parent_id` (a self-reference) and `position`
  (sibling order) from `KilnCMS.CMS.Content`. A page under a page, a guide under
  a section: structure as a property of the content, rather than something an
  editor restates in a navigation menu and then has to keep in sync by hand.

  ## What this is not

  **Not the term hierarchy.** `KilnCMS.CMS.Category` and `KilnCMS.CMS.Tag` say
  what a document is *about*; the tree says where it *sits*. They are different
  axes and neither may impersonate the other — a document deep in the tree is
  not thereby filed under its ancestors' categories. (#1595 will give terms their
  own hierarchy; that is a separate parent.)

  **Not a change to URL resolution.** D21 is additive precisely because Kiln
  already serves multi-segment paths: `path_alias` (#485) resolves them,
  `KilnCMS.CMS.Validations.PathAliasValid` shapes them, and
  `KilnCMS.CMS.Changes.RecordSlugRedirect` already records a 301 when one is
  added, changed or removed. A record with no parent, or no ancestor-derived
  alias, resolves exactly as it did before the tree existed. Deriving an alias
  *from* the chain is a later slice and a new `alias_pattern` token — not new
  resolution.

  **Not the same tree as a menu.** `KilnCMS.CMS.MenuItem` keeps its own, because
  a navigation menu is an editorial selection: it omits things, reorders them,
  and points at external URLs. Deriving menus from this tree is deliberately out
  of scope for the first release of it.

  ## Same type only

  A parent is a record of the **same** content type, so the reference is a real
  foreign key per table rather than a bare UUID. Cross-type parenting would mean
  giving up referential integrity for a relationship whose whole value is that it
  is structural (D4 prefers the strongly-modelled option where there is one).
  Cross-type *relations* already have a home: `KilnCMS.CMS.ContentLink`.

  Deleting a parent never deletes its children. The FK nilifies, so a purged
  parent leaves its children as roots rather than taking a subtree of published
  documents with it — the same call `KilnCMS.CMS.Tag` makes for its group, for
  the same reason, and with more at stake.

  ## Depth is capped

  `max_depth/0` levels, root at 1. The cap is not decoration: it is what makes
  the ancestor walk in `KilnCMS.CMS.Validations.ContentPlacement` terminate in a
  bounded number of point reads, and what bounds the alias derivation a later
  slice hangs off the same chain.

  ## Why no materialized path (yet)

  Ancestry is read by walking `parent_id` upward, bounded by `max_depth/0` — not
  from a denormalized path column, and not through a recursive CTE.

  The walk is a handful of primary-key reads at a depth of at most
  `max_depth/0` levels, and it keeps **one** copy of the truth. A materialized path is the
  faster read, but it is derived state that every move has to rewrite for the
  whole subtree — which is the fan-out D21 already flags as the thing to measure,
  and paying it on every write to make an at-most-five-step walk cheaper is the
  wrong trade until a read path actually needs ancestry in bulk.

  If one does — a sitemap, a breadcrumb on a hot delivery route, a tree view over
  thousands of rows — the answer is a recursive CTE behind a single function
  here, or a materialized path added as a cache with the walk as its oracle.
  Both are additive. Choosing one now, on a guess about which read gets hot,
  would be the expensive mistake.
  """

  # Five levels. `/docs/guides/advanced/flags` is four and already a deep site;
  # past five, structure has stopped being navigable and wants a search box. The
  # bound exists to make the walks terminate as a schema property rather than a
  # convention (the reasoning `KilnCMS.CMS.MenuItem` gives for its own, shallower
  # cap — three, because a menu is a navigation aid and not a sitemap).
  @max_depth 5

  @doc """
  Deepest level a document may sit at; a root document is depth 1.

  Counted over the whole subtree a move carries, not just the moved record —
  see `KilnCMS.CMS.Validations.ContentPlacement`.
  """
  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth
end
