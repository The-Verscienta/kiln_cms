defmodule KilnCMS.CMS.Changes.DeleteArtifacts do
  @moduledoc """
  Removes a document's fired artifacts and evicts the cache after an unpublish
  transition (Kiln v2 — decision D9). Best-effort; never fails the unpublish.
  """
  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      with {:ok, record} <- result do
        try do
          type = KilnCMS.Firing.Engine.document_type(record)
          KilnCMS.Firing.Engine.purge(record.org_id, type, record.id)

          # Drop it from the optional Meilisearch index (Phase 6). No-op when the
          # backend is disabled.
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
        rescue
          error ->
            Logger.error("Artifact purge failed for #{inspect(record.id)}: #{inspect(error)}")
        end

        {:ok, record}
      end
    end)
  end
end
