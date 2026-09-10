defmodule KilnCMS.Media.Bulk do
  @moduledoc """
  Batched bulk operations for the media library (#1316).

  Bulk tagging through `MediaItem.:update`'s merge verbs runs a full changeset
  pipeline per item — a policy pass, a `manage_relationship` load of the
  item's current tags, a tag lookup, and the join write, serially inside one
  LiveView event. A 60-item selection lands in the hundreds-of-queries range
  while the socket blocks.

  These helpers write the shared polymorphic `Tagging` join directly instead:
  one read to find what's already linked, then one bulk insert (or one bulk
  destroy). The rows are exactly what `manage_relationship` would have
  produced, created under the same authorization — `Tagging`'s own policies
  (editor-and-up writes, read-scoped API keys refused) run with the caller's
  actor, and the tenant scopes both the reads and the writes.

  Semantics match the merge verbs: adding a tag an item already carries is a
  no-op, and removing a tag an item doesn't carry is a no-op. The one
  divergence from the per-item path is a concurrent-tagging race (another
  editor tags the same item between the read and the insert), which surfaces
  as a failed row — the same "has already been taken" outcome the per-item
  path had.
  """

  alias KilnCMS.CMS.Tagging

  require Ash.Query

  @doc """
  Tag every item in `items` with `tag_id`.

  Returns `{ok_count, failed_count}` over the ITEMS (already-tagged items
  count as ok). `opts` must carry `:actor` and `:tenant`.
  """
  @spec add_tag([struct()], Ash.UUID.t(), keyword()) ::
          {non_neg_integer(), non_neg_integer()}
  def add_tag(items, tag_id, opts) do
    ids = Enum.map(items, & &1.id)

    already_tagged =
      Tagging
      |> Ash.Query.filter(tag_id == ^tag_id and subject_id in ^ids)
      |> Ash.read!(scope(opts))
      |> MapSet.new(& &1.subject_id)

    case Enum.reject(ids, &MapSet.member?(already_tagged, &1)) do
      [] ->
        {length(items), 0}

      missing ->
        result =
          missing
          |> Enum.map(&%{subject_id: &1, tag_id: tag_id})
          |> Ash.bulk_create(Tagging, :create, bulk_opts(opts))

        failed = result.error_count || 0
        {length(items) - failed, failed}
    end
  end

  @doc """
  Remove `tag_id` from every item in `items`.

  Returns `{ok_count, failed_count}` over the ITEMS (items not carrying the
  tag count as ok — removing an absent link is idempotent). `opts` must carry
  `:actor` and `:tenant`.
  """
  @spec remove_tag([struct()], Ash.UUID.t(), keyword()) ::
          {non_neg_integer(), non_neg_integer()}
  def remove_tag(items, tag_id, opts) do
    ids = Enum.map(items, & &1.id)

    result =
      Tagging
      |> Ash.Query.filter(tag_id == ^tag_id and subject_id in ^ids)
      |> Ash.bulk_destroy(:destroy, %{}, bulk_opts(opts))

    failed = result.error_count || 0
    {max(length(items) - failed, 0), failed}
  end

  defp scope(opts), do: Keyword.take(opts, [:actor, :tenant])

  defp bulk_opts(opts) do
    scope(opts) ++
      [authorize?: true, return_errors?: true, stop_on_error?: false, return_records?: false]
  end
end
