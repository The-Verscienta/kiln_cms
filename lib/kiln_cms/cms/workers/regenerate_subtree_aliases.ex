defmodule KilnCMS.CMS.Workers.RegenerateSubtreeAliases do
  @moduledoc """
  After a document moves in the content tree (#1597, D21), re-derive the path
  aliases of it **and everything beneath it**.

  A document's `[ancestors]`-derived path is a function of its ancestor chain,
  so moving a section changes the correct path of every document under it — not
  just the one that moved. That fan-out is why this is a job rather than part of
  the move:

    * it is unbounded in principle (a deep section carries its whole subtree),
      so it must not sit inside the write an editor is waiting on;
    * every rewrite goes through the type's `:update`, which records a 301,
      re-fires artifacts and busts caches — work that belongs after the commit,
      not inside it;
    * reading the subtree inside the move's transaction is the hazard
      `after_action` DB reads already are here. Enqueuing costs one row.

  The window this opens is benign: until the job runs, a descendant keeps the
  path it already had, which still resolves. When the job lands, the new path
  serves and `KilnCMS.CMS.Changes.RecordSlugRedirect` has left a 301 on the old
  one — and `KilnCMS.CMS.Redirect` points at the *record*, resolving its current
  URL per request, so repeated moves never chain.

  Nothing here overwrites a hand-written alias: the regeneration skips
  author-pinned values (`KilnCMS.CMS.Slugs.underived?/2`), the same rule the
  bulk tool applies. An operator who wants those rewritten too has
  `mix kiln.slugs.regenerate --include-pinned` and says so deliberately.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.SlugRegeneration
  alias KilnCMS.CMS.Slugs

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kind" => kind, "id" => id, "org_id" => org_id} = args}) do
    ct = ContentTypes.get!(kind, org_id)

    # Nothing to derive from: the type's aliases are manual, so a move must not
    # touch them.
    if is_nil(ct.alias_pattern) do
      :ok
    else
      rows = tree_rows(ct, org_id)

      SlugRegeneration.run(kind, org_id,
        field: :path_alias,
        ids: subtree_ids(rows, id),
        # The chains as they were before the move, so the regeneration can tell
        # a stale derived alias from a hand-written one (#1890). Only the moved
        # record's parent changed, so rewinding that one edge rewinds the whole
        # subtree.
        prior_ancestors: chains(rewind(rows, id, args["old_parent_id"]))
      )

      :ok
    end
  end

  # The subtree's structure is unchanged by the move — only the moved record's
  # own parent moved — so putting that one edge back gives every pre-move chain.
  defp rewind(rows, id, old_parent_id) do
    Enum.map(rows, fn
      %{id: ^id} = row -> %{row | parent_id: old_parent_id}
      row -> row
    end)
  end

  # `id => [ancestor slug, …]`, root first, for every row.
  defp chains(rows) do
    by_id = Map.new(rows, &{&1.id, &1})
    Map.new(rows, &{&1.id, climb(by_id, &1.parent_id, [], 0)})
  end

  defp climb(_by_id, nil, acc, _depth), do: acc

  defp climb(by_id, id, acc, depth) do
    if depth > KilnCMS.CMS.ContentTree.max_depth() do
      acc
    else
      case Map.get(by_id, id) do
        nil -> acc
        row -> climb(by_id, row.parent_id, [row.slug | acc], depth + 1)
      end
    end
  end

  defp tree_rows(ct, org_id) do
    ct
    |> Slugs.storage_resource()
    |> Ash.Query.select([:id, :parent_id, :slug])
    # authorize?: false — the subtree has to be complete. A descendant the job
    # could not read is one whose path would silently keep pointing at the old
    # structure, which is the bug this worker exists to prevent; and a draft
    # ancestor still contributes its segment. A system actor is the wrong tool
    # here: a refused read returns `{:ok, []}`, so an unreadable row would
    # flatten a path rather than fail loudly. Ids and slugs only, tenant-scoped.
    |> Ash.read!(authorize?: false, tenant: org_id)
  end

  # The moved record and everything beneath it, off the rows already read — a
  # per-level query would turn one move into a query per level of the subtree.
  defp subtree_ids(rows, id) do
    by_parent = Enum.group_by(rows, & &1.parent_id)
    collect(by_parent, [id], [])
  end

  defp collect(_by_parent, [], acc), do: acc

  defp collect(by_parent, [id | rest], acc) do
    if id in acc do
      collect(by_parent, rest, acc)
    else
      children = by_parent |> Map.get(id, []) |> Enum.map(& &1.id)
      collect(by_parent, rest ++ children, [id | acc])
    end
  end
end
