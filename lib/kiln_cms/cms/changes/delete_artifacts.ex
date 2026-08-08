defmodule KilnCMS.CMS.Changes.DeleteArtifacts do
  @moduledoc """
  Removes a document's fired artifacts and evicts the cache after an unpublish
  transition (Kiln v2 — decision D9). Best-effort; never fails the unpublish.

  ## Referrers are re-fired too

  `Engine.purge/3` drops *this* document's artifacts. That is not the whole
  teardown once a document can be **inlined** into another (#479): a fragment's
  body is copied into every artifact that embeds it, so purging only its own
  rows leaves the withdrawn text live in its referrers — served to anonymous
  callers through the artifact controller, the feeds, the static export and the
  newsletter, until something unrelated happened to re-fire them.

  Nothing did. `References.invalidate/4` was reachable only from the *fire* path,
  i.e. only when a document was published (#917). Withdrawing content is the one
  operation this has to get right, so the same wave now runs on the way down.
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

          # Seeded with this document's own key so the wave cannot come back to
          # the record being torn down. Same cycle-safety contract the fire path
          # uses.
          KilnCMS.Firing.References.invalidate(record.org_id, type, record.id, [
            KilnCMS.Firing.References.key(type, record.id)
          ])

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
