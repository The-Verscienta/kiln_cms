defmodule KilnCMS.CMS.Changes.FireArtifacts do
  @moduledoc """
  Fires a document into immutable per-surface artifacts after a publish
  transition (Kiln v2 — decision D9). Runs in `after_transaction` so it sees the
  committed record. Firing failures are logged but never fail the publish.
  """
  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      with {:ok, record} <- result do
        try do
          KilnCMS.Firing.Engine.fire(record)
          # Re-fire downstream referrers whose embedded snapshot is now stale (D13).
          type = KilnCMS.Firing.Engine.document_type(record)

          KilnCMS.Firing.References.invalidate(type, record.id, [
            KilnCMS.Firing.References.key(type, record.id)
          ])
        rescue
          error -> Logger.error("Firing failed for #{inspect(record.id)}: #{inspect(error)}")
        end

        {:ok, record}
      end
    end)
  end
end
