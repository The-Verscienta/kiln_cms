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

  alias KilnCMS.CMS.ContentTree
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
      resource = Slugs.storage_resource(ct)

      # The subtree alone, not the type (#1903): one recursive CTE down from the
      # moved record, and one up from each of its parents, new and old.
      # authorize?-free and complete on purpose — a descendant the job could not
      # read is one whose path would silently keep pointing at the old
      # structure, and a draft ancestor still contributes its segment.
      rows = ContentTree.subtree(resource, id, org_id)
      parent_id = Enum.find_value(rows, &(&1.id == id && &1.parent_id))

      SlugRegeneration.run(kind, org_id,
        field: :path_alias,
        ids: Enum.map(rows, & &1.id),
        ancestors:
          ContentTree.subtree_chains(rows, id, ContentTree.chain(resource, parent_id, org_id)),
        # The chains as they were before the move, so the regeneration can tell
        # a stale derived alias from a hand-written one (#1890). Only the moved
        # record's parent changed, so rooting the same subtree at the OLD
        # parent's chain rewinds every chain beneath it.
        prior_ancestors:
          ContentTree.subtree_chains(
            rows,
            id,
            ContentTree.chain(resource, args["old_parent_id"], org_id)
          )
      )

      :ok
    end
  end
end
