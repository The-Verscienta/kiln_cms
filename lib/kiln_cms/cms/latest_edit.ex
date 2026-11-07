defmodule KilnCMS.CMS.LatestEdit do
  @moduledoc """
  The read-back of the change severity (`KilnCMS.CMS.Severity`): how much the
  most recent *safety* edit of a published document mattered, and when it was
  made.

  "Latest edit" is the newest version row of the document (ordered by
  `(version_inserted_at, id)`) that carries a `change_severity`. Severity is
  only stored on a published edit that touched a safety field, so a later edit
  of an unlisted field does not move it: the answer is the last edit of
  something the site called safety-relevant, which is what a reader deciding
  "is my copy stale in a way that matters" wants. Versions written before the
  column existed hold `nil` and never appear; a document with none reads `nil`.

  Deliberately not anchored on `published_version_id`: that pointer is not
  re-pointed by a live `:update`, is written after the transaction, and is
  deferred by releases.

  `for_records/1` answers a whole page with one query per tenant. The version
  rows are read with `authorize?: false` — they are editor-only history — and
  only `change_severity` and `version_inserted_at` are selected, never
  `changes` (the draft snapshot). The result is the same data the public site
  shows, and callers pass records they were already allowed to read; a record
  that is not currently published gets no entry.

  A failed read degrades: the group it covered answers "no edit" (and the
  failure is logged) rather than raising out of a content read or `/api/sync`.

  The `(version_inserted_at desc, id desc)` order assumes a document's
  severity-bearing versions are written by separate statements. Their
  timestamps are taken per write (`DateTime.utc_now/0`, microseconds), not per
  transaction, so even two safety edits of one document in one transaction
  order by the clock; `id` only breaks an exact microsecond tie. A partial
  index on `(org_id, version_source_id, version_inserted_at desc, id desc)
  WHERE change_severity IS NOT NULL` keeps the lookup off the rest of the
  history.
  """
  require Ash.Query
  require Logger

  @type edit :: %{severity: atom(), at: DateTime.t()}

  @doc """
  `%{record_id => %{severity: atom, at: DateTime.t()}}` for the published
  records in `records` that have a latest edit. Everything else is absent.
  """
  @spec for_records([struct()]) :: %{Ash.UUID.t() => edit()}
  def for_records(records) do
    records
    |> Enum.filter(&match?(%{state: :published}, &1))
    |> Enum.group_by(&{&1.__struct__, &1.org_id}, & &1.id)
    |> Enum.reduce(%{}, fn {{resource, org_id}, ids}, acc ->
      Map.merge(acc, latest(resource, org_id, Enum.uniq(ids)))
    end)
  end

  defp latest(resource, org_id, ids) do
    version = Module.concat(resource, Version)

    # authorize?: false — version history is editor-only and the callers pass
    # records they may already read; only the two columns below are selected.
    version
    |> Ash.Query.filter(version_source_id in ^ids and not is_nil(change_severity))
    |> Ash.Query.select([:version_source_id, :change_severity, :version_inserted_at])
    |> Ash.Query.distinct([:version_source_id])
    |> Ash.Query.distinct_sort(version_inserted_at: :desc, id: :desc)
    |> Ash.Query.set_tenant(org_id)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, versions} ->
        Map.new(
          versions,
          &{&1.version_source_id, %{severity: &1.change_severity, at: &1.version_inserted_at}}
        )

      {:error, reason} ->
        Logger.warning("latest edit lookup failed, answering no edit: #{inspect(reason)}")
        %{}
    end
  end
end
