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

  The first bulk reader was the move itself: `subtree/3` and `chain/3` are those
  CTEs, and a subtree move reads its subtree with them rather than the whole
  type (#1903). The measured cost of a large move is in `docs/benchmarks.md`.
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

  @doc """
  The documents of `type` that `record` may legally be moved under, in tree
  order, each with the `depth` it sits at so a picker can indent them.

  Excluded: `record` itself, everything in its subtree, and any document deep
  enough that landing `record`'s own subtree beneath it would pass
  `max_depth/0`. That is the same arithmetic
  `KilnCMS.CMS.Validations.ContentPlacement` does — `ancestors + 1 + height` —
  which is the point: **this offers, the validation decides.** A picker built
  from this cannot propose a move the write would refuse, and a caller that
  ignores it is still refused. Keeping the rule in two places is the trade for
  not making the editor discover it by being rejected, and the duplication is
  one-directional: this may only ever be *more* restrictive than the write.

  One query. Depth, descendants and subtree height all come from the same
  `(id, title, parent_id)` rows, walked in memory, because a tree small enough
  to put in a `<select>` is small enough to sort in the VM.

  `record` may be `nil` (nothing is being moved), in which case every document
  within the cap is a candidate.

  ## Scale

  This reads **every** document of the type. That is the right shape for the
  sites the picker is for and the wrong one for a site with thousands of pages,
  where both the query and a flat `<select>` stop being reasonable. The fix when
  that lands is a search-as-you-type parent picker over
  `KilnCMS.CMS.ContentTypes.list!/2`'s existing filters, not a cleverer walk —
  so this stays deliberately plain rather than half-optimised for a case it
  does not serve.
  """
  @spec candidate_parents(term(), struct() | nil, keyword()) ::
          [%{id: Ecto.UUID.t(), title: String.t() | nil, depth: pos_integer()}]
  def candidate_parents(type, record, opts \\ []) do
    rows = tree_rows(type, opts)
    moving_id = record && Map.get(record, :id)

    by_parent = Enum.group_by(rows, & &1.parent_id)
    blocked = if moving_id, do: subtree_ids(by_parent, moving_id), else: %{}
    headroom = @max_depth - 1 - height(by_parent, moving_id)

    by_parent
    |> walk(nil, 1)
    |> Enum.reject(&(Map.has_key?(blocked, &1.id) or &1.depth > headroom))
  end

  @doc """
  `record`'s ancestors, root first — where it sits, for a breadcrumb.

  Bounded by `max_depth/0` plus one: a longer chain means a cycle committed by
  two concurrent moves, and this returns what it has rather than spinning.
  """
  @spec ancestors(term(), struct(), keyword()) :: [%{id: Ecto.UUID.t(), title: String.t() | nil}]
  def ancestors(type, record, opts \\ []) do
    by_id = type |> tree_rows(opts) |> Map.new(&{&1.id, &1})

    climb(by_id, Map.get(record, :parent_id), [])
  end

  defp climb(_by_id, nil, acc), do: acc

  defp climb(by_id, id, acc) when length(acc) <= @max_depth do
    case Map.get(by_id, id) do
      nil -> acc
      row -> climb(by_id, row.parent_id, [%{id: row.id, title: row.title} | acc])
    end
  end

  defp climb(_by_id, _id, acc), do: acc

  @doc """
  `id` and every document beneath it, as `%{id, parent_id, slug}` rows — one
  recursive CTE scoped to the subtree (#1903), so a move under a type with tens
  of thousands of rows reads the rows it moved and not the type.

  `resource` is the storage resource (`KilnCMS.CMS.Slugs.storage_resource/1`).
  Each level is an index scan on `parent_id`. The recursion stops at
  `max_depth/0` levels below `id`, so a cycle committed by two concurrent moves
  terminates rather than spins; a row reached twice that way is returned once.

  Unauthorized and tenant-scoped by `org_id`: a subtree has to be complete to
  re-derive its paths, a draft included (see
  `KilnCMS.CMS.Workers.RegenerateSubtreeAliases`). Ids and slugs only.
  """
  @spec subtree(module(), Ecto.UUID.t(), Ecto.UUID.t()) :: [
          %{id: Ecto.UUID.t(), parent_id: Ecto.UUID.t() | nil, slug: String.t() | nil}
        ]
  def subtree(resource, id, org_id) do
    %{rows: rows} =
      KilnCMS.Repo.query!(
        """
        WITH RECURSIVE sub AS (
          SELECT id, parent_id, slug, 0 AS depth
          FROM #{table(resource)} WHERE id = $1 AND org_id = $2
          UNION ALL
          SELECT c.id, c.parent_id, c.slug, sub.depth + 1
          FROM #{table(resource)} c JOIN sub ON c.parent_id = sub.id
          WHERE c.org_id = $2 AND sub.depth < $3
        )
        SELECT id, parent_id, slug FROM sub
        """,
        [dump_uuid(id), dump_uuid(org_id), @max_depth]
      )

    rows
    |> Enum.map(fn [id, parent_id, slug] ->
      %{id: load_uuid(id), parent_id: parent_id && load_uuid(parent_id), slug: slug}
    end)
    |> Enum.uniq_by(& &1.id)
  end

  @doc """
  The slugs of `id` and its ancestors, root first — the `[ancestors]` chain of a
  document whose parent is `id`. `[]` for `nil` (a root). One recursive CTE,
  bounded like `subtree/3`.
  """
  @spec chain(module(), Ecto.UUID.t() | nil, Ecto.UUID.t()) :: [String.t()]
  def chain(_resource, nil, _org_id), do: []

  def chain(resource, id, org_id) do
    %{rows: rows} =
      KilnCMS.Repo.query!(
        """
        WITH RECURSIVE up AS (
          SELECT id, parent_id, slug, 0 AS depth
          FROM #{table(resource)} WHERE id = $1 AND org_id = $2
          UNION ALL
          SELECT p.id, p.parent_id, p.slug, up.depth + 1
          FROM #{table(resource)} p JOIN up ON p.id = up.parent_id
          WHERE p.org_id = $2 AND up.depth < $3
        )
        SELECT slug FROM up ORDER BY depth DESC
        """,
        [dump_uuid(id), dump_uuid(org_id), @max_depth]
      )

    Enum.map(rows, fn [slug] -> slug end)
  end

  @doc """
  `id => [ancestor slug, …]` (root first) for every row of `rows`, a subtree as
  `subtree/3` returns it rooted at `root_id`, given the chain above the root.

  Linear in the subtree: each row's chain is its parent's plus one segment,
  walked down from the root with a work list that is prepended to.
  """
  @spec subtree_chains([map()], Ecto.UUID.t(), [String.t()]) :: %{Ecto.UUID.t() => [String.t()]}
  def subtree_chains(rows, root_id, root_chain) do
    by_parent = Enum.group_by(rows, & &1.parent_id)
    slugs = Map.new(rows, &{&1.id, &1.slug})
    descend(by_parent, slugs, [{root_id, root_chain}], %{})
  end

  defp descend(_by_parent, _slugs, [], acc), do: acc

  defp descend(by_parent, slugs, [{id, chain} | rest], acc) do
    if Map.has_key?(acc, id) do
      descend(by_parent, slugs, rest, acc)
    else
      below = chain ++ [Map.get(slugs, id)]

      work =
        by_parent
        |> Map.get(id, [])
        |> Enum.reduce(rest, fn child, work -> [{child.id, below} | work] end)

      descend(by_parent, slugs, work, Map.put(acc, id, chain))
    end
  end

  defp table(resource), do: AshPostgres.DataLayer.Info.table(resource)

  defp dump_uuid(id), do: Ecto.UUID.dump!(id)
  defp load_uuid(raw), do: Ecto.UUID.load!(raw)

  defp tree_rows(type, opts) do
    KilnCMS.CMS.ContentTypes.list!(
      type,
      Keyword.put(opts, :query,
        select: [:id, :title, :parent_id, :position],
        sort: [position: :asc, title: :asc]
      )
    )
  end

  # Depth-first from `parent`, carrying the depth each row sits at.
  defp walk(by_parent, parent, depth) do
    by_parent
    |> Map.get(parent, [])
    |> Enum.flat_map(fn row ->
      [%{id: row.id, title: row.title, depth: depth} | walk(by_parent, row.id, depth + 1)]
    end)
  end

  # `id` and everything beneath it, as a map used as a set (`id => []`).
  # Bounded by the row count, so a cycle committed by concurrent moves cannot
  # spin it.
  #
  # A plain map rather than a MapSet: OTP 29's dialyzer loses MapSet's opacity
  # through a recursive accumulator (and through the `MapSet.new/0` union in
  # `candidate_parents/3`) and reports `call_without_opaque`. The set never
  # leaves this module, and `:sets` v2 stores this exact shape underneath.
  defp subtree_ids(by_parent, id) do
    collect(by_parent, [id], %{})
  end

  defp collect(_by_parent, [], seen), do: seen

  defp collect(by_parent, [id | rest], seen) do
    if Map.has_key?(seen, id) do
      collect(by_parent, rest, seen)
    else
      # Prepended, not appended: `rest ++ children` copied the whole work list
      # per node, quadratic in the subtree (#1903). Order is irrelevant to a set.
      work = by_parent |> Map.get(id, []) |> Enum.reduce(rest, &[&1.id | &2])
      collect(by_parent, work, Map.put(seen, id, []))
    end
  end

  # Levels below `id`; 0 for a leaf or for nothing being moved.
  defp height(_by_parent, nil), do: 0

  defp height(by_parent, id) do
    case Map.get(by_parent, id, []) do
      [] -> 0
      children -> 1 + (children |> Enum.map(&height(by_parent, &1.id)) |> Enum.max())
    end
  end
end
