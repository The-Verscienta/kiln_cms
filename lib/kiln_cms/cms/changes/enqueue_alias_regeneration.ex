defmodule KilnCMS.CMS.Changes.EnqueueAliasRegeneration do
  @moduledoc """
  After a `:move` (#1597, D21), enqueue
  `KilnCMS.CMS.Workers.RegenerateSubtreeAliases` for the moved document and
  everything beneath it.

  A path derived with `[ancestors]` is a function of the ancestor chain, so a
  move changes the correct path of the whole subtree, not just the record that
  moved. See the worker for why that is a job and not part of the write.

  Enqueued **unconditionally on a move**, rather than after checking whether
  there is anything to do. The check would be a read of the subtree inside
  `after_action`, which is the transaction hazard this is shaped to avoid — and
  the answer is almost always yes anyway, because the moved record's own path
  changed. The worker is the cheap place to decide there is nothing to derive: a
  type with no alias pattern returns immediately.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Workers.RegenerateSubtreeAliases

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, &enqueue/2)
  end

  defp enqueue(changeset, record) do
    # Where it sat BEFORE this move. The worker rewinds that one edge to
    # reconstruct every pre-move chain, which is how it tells a stale derived
    # alias from a hand-written one (#1890). `changeset.data` is the row as it
    # was, so this is the old parent even though the attribute is changing.
    %{
      "kind" => ContentTypes.type_name_for(changeset),
      "id" => record.id,
      "org_id" => record.org_id,
      "old_parent_id" => Map.get(changeset.data, :parent_id)
    }
    |> RegenerateSubtreeAliases.new()
    |> Oban.insert!()

    {:ok, record}
  end
end
