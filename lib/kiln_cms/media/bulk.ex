defmodule KilnCMS.Media.Bulk do
  @moduledoc """
  Batched bulk operations for the media library (#1316).

  ## Tagging

  Bulk tagging through `MediaItem.:update`'s merge verbs runs a full changeset
  pipeline per item — a policy pass, a `manage_relationship` load of the
  item's current tags, a tag lookup, and the join write, serially inside one
  LiveView event. A 60-item selection lands in the hundreds-of-queries range
  while the socket blocks.

  `add_tag/3` and `remove_tag/3` write the shared polymorphic `Tagging` join
  directly instead: resolve the tag once, read what's already linked, then
  one bulk insert (or one bulk destroy). Three guards keep the shortcut
  equivalent to the per-item path:

    * **The tag is resolved under the tenant first.** `manage_relationship`'s
      tenant-scoped lookup is the documented cross-org guard (see
      `Tagging`'s multitenancy comment) — without it, a foreign org's
      `tag_id` would insert straight through the join's plain FK. A tag that
      doesn't resolve (other org's, deleted, nonexistent) fails every item
      up front.
    * **The caller's write access is checked up front** (`Ash.can?` against
      `Tagging`'s create/destroy — actor-only policies, so the empty-changeset
      check is accurate). Without this, the all-already-tagged short-circuit
      would report success to a caller the policies would refuse.
    * **A failed batch counts every attempted item as failed.** The insert is
      one `insert_all` per batch, so a single violating row (e.g. the
      concurrent-tagging race between the read and the insert) aborts the
      whole statement — per-row accounting would report phantom successes.
      Conservative on multi-batch partial success, but never a lie; the
      errors are logged rather than discarded.

  `subject_id` is trusted from the caller: pass only records the actor's own
  tenant-scoped read returned (the media library passes its loaded grid).

  ## Deleting

  `delete/2` owns the skip-and-compensate cache contract for bulk deletes:
  each destroy suppresses `BustMediaCache`'s full published-cache clear
  (`skip_media_cache_bust`), and ONE clear runs after the loop — including
  when a destroy raises mid-loop, since an unknown number of earlier
  destroys have already committed. Keeping loop, flag, and compensating bust
  in one function body is what makes the contract enforceable rather than a
  comment two files apart.
  """

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Changes.BustMediaCache
  alias KilnCMS.CMS.Tagging

  require Ash.Query
  require Logger

  @doc """
  Tag every item in `items` with `tag_id`.

  Returns `{ok_count, failed_count}` over the ITEMS (already-tagged items
  count as ok; a tag that doesn't resolve under the tenant, or a caller
  `Tagging`'s policies refuse, fails all of them). `opts` must carry
  `:actor` and `:tenant`.
  """
  @spec add_tag([struct()], Ash.UUID.t(), keyword()) ::
          {non_neg_integer(), non_neg_integer()}
  def add_tag(items, tag_id, opts) do
    with :ok <- check_tag_in_tenant(tag_id, opts),
         :ok <- check_allowed(:create, opts) do
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

          settle(result, items, missing, "bulk tag")
      end
    else
      :refused -> {0, length(items)}
    end
  end

  @doc """
  Remove `tag_id` from every item in `items`.

  Returns `{ok_count, failed_count}` over the ITEMS (items not carrying the
  tag count as ok — removing an absent link is idempotent, and a tag id that
  resolves to nothing under the tenant simply matches no rows). `opts` must
  carry `:actor` and `:tenant`.
  """
  @spec remove_tag([struct()], Ash.UUID.t(), keyword()) ::
          {non_neg_integer(), non_neg_integer()}
  def remove_tag(items, tag_id, opts) do
    case check_allowed(:destroy, opts) do
      :refused ->
        {0, length(items)}

      :ok ->
        ids = Enum.map(items, & &1.id)

        result =
          Tagging
          |> Ash.Query.filter(tag_id == ^tag_id and subject_id in ^ids)
          |> Ash.bulk_destroy(:destroy, %{}, bulk_opts(opts))

        # The destroy runs as one atomic DELETE — it either removed every
        # matching row or none, so a failure fails all items (no clamp: a
        # partial count here would be a lie).
        case result.status do
          :success ->
            {length(items), 0}

          _failed ->
            Logger.warning("bulk untag failed: #{inspect(result.errors)}")
            {0, length(items)}
        end
    end
  end

  @doc """
  Soft-delete every item in `items` (the library's bulk delete).

  Each destroy suppresses the per-record full published-cache clear; one
  clear runs after the loop whenever anything was destroyed — even when a
  destroy raises mid-loop, because earlier destroys have already committed.
  Per-item results, not all-or-nothing: an item another admin already
  trashed must not sink the rest. Returns `{ok_count, failed_count}`;
  `opts` must carry `:actor` and `:tenant`.
  """
  @spec delete([struct()], keyword()) :: {non_neg_integer(), non_neg_integer()}
  def delete(items, opts) do
    destroy_opts = scope(opts) ++ [context: %{skip_media_cache_bust: true}]

    {ok, failed} =
      try do
        Enum.split_with(items, &(CMS.destroy_media_item(&1, destroy_opts) == :ok))
      rescue
        # Expected failures come back as error tuples; a raise (DB disconnect,
        # ownership timeout) means an unknown number of destroys already
        # committed — bust before re-raising so none serves stale from cache.
        error ->
          BustMediaCache.bust()
          reraise error, __STACKTRACE__
      end

    if ok != [], do: BustMediaCache.bust()
    {length(ok), length(failed)}
  end

  # The tenant-scoped resolution `manage_relationship` performed — THE
  # cross-org guard (a foreign tag simply won't resolve under the tenant).
  defp check_tag_in_tenant(tag_id, opts) do
    case CMS.get_tag(tag_id, scope(opts)) do
      {:ok, _tag} -> :ok
      _not_found -> :refused
    end
  end

  # Tagging's write policies are actor-only SimpleChecks, so the
  # empty-changeset `Ash.can?` is an accurate gate — see the moduledoc.
  defp check_allowed(action, opts) do
    if Ash.can?({Tagging, action}, opts[:actor], tenant: opts[:tenant]),
      do: :ok,
      else: :refused
  end

  # Batch accounting: the insert is all-or-nothing per statement, so any
  # failure counts every ATTEMPTED row as failed (already-tagged items stay
  # ok). Never phantom successes; errors logged, not discarded.
  defp settle(result, items, attempted, label) do
    case result.status do
      :success ->
        {length(items), 0}

      _failed ->
        Logger.warning(
          "#{label} failed for #{length(attempted)} item(s): #{inspect(result.errors)}"
        )

        {length(items) - length(attempted), length(attempted)}
    end
  end

  defp scope(opts), do: Keyword.take(opts, [:actor, :tenant])

  defp bulk_opts(opts) do
    scope(opts) ++
      [authorize?: true, return_errors?: true, stop_on_error?: false, return_records?: false]
  end
end
