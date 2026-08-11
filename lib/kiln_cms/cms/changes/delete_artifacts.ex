defmodule KilnCMS.CMS.Changes.DeleteArtifacts do
  @moduledoc """
  Removes a document's fired artifacts and evicts the cache after an unpublish
  transition (Kiln v2 — decision D9). Best-effort; never fails the unpublish.

  ## It also re-fires the referrers (#917)

  Purging this document's own artifacts is only half of withdrawing it. Since
  #479 a referrer **inlines** what it points at — a `Fragment` block is replaced
  by the target's blocks at fire time — so the target's body is sitting inside
  every referrer's `:web`/`:json`/`:llm`/`:json_ld` artifacts too.

  The re-fire wave was wired to the *publish* path only (`FireWorker`'s
  `{:ok, document}` branch), so unpublishing a fragment left every page that
  embedded it serving the withdrawn body to anonymous callers, through feeds,
  static export and the newsletter. Only the 60-minute HTML payload cache
  self-healed.

  Withdrawing a fragment is the operation an editor reaches for to *retract*
  something, so it is the one case this has to get right. `invalidate/4` is the
  same call the publish path makes; the referrers re-fire, `Fragments.expand/3`
  finds the target no longer published, and it expands to nothing.
  """
  use Ash.Resource.Change

  require Logger

  alias KilnCMS.Firing.Engine
  alias KilnCMS.Firing.References

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      with {:ok, record} <- result do
        purge(record)
        {:ok, record}
      end
    end)
  end

  # Each step is independently best-effort: a failure to purge must not stop the
  # referrer wave, and neither must stop the unpublish, which has already
  # committed by the time this runs.
  defp purge(record) do
    type = Engine.document_type(record)

    attempt("artifact purge", record, fn ->
      Engine.purge(record.org_id, type, record.id)
    end)

    attempt("referrer invalidation", record, fn ->
      # Seeded with this document, exactly as the publish path seeds it, so a
      # self-referencing document doesn't re-enqueue itself forever.
      References.invalidate(record.org_id, type, record.id, [
        References.key(type, record.id)
      ])
    end)

    attempt("search de-index", record, fn -> deindex(record, type) end)
  end

  # Drop it from the optional Meilisearch index (Phase 6). No-op when the
  # backend is disabled.
  defp deindex(record, type) do
    if KilnCMS.Search.Meilisearch.enabled?() do
      %{
        "org_id" => record.org_id,
        "op" => "delete",
        "type" => to_string(type),
        "id" => record.id
      }
      |> KilnCMS.Search.MeilisearchWorker.new()
      |> Oban.insert()
    end
  end

  defp attempt(label, record, fun) do
    fun.()
    :ok
  rescue
    error ->
      Logger.error("#{label} failed for #{inspect(record.id)}: #{inspect(error)}")
      :ok
  end
end
