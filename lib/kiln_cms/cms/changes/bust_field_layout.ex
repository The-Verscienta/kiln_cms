defmodule KilnCMS.CMS.Changes.BustFieldLayout do
  @moduledoc """
  Drops a site's cached type registry and delivery schemas after a
  `KilnCMS.CMS.FieldSection` write (#2280), so a section laid out as tabs
  shows in `GET /api/schema` (`x-kiln-section-display`) on the next request
  instead of after the TTL.

  Not `Changes.BustTypeRegistry`: that change reads its record as a type or a
  field definition and re-fires a type's documents when a field's delivered
  shape changes. A layout changes no document, so there is nothing to re-fire
  — only the cached views of the schema to drop.

  After the commit, through `KilnCMS.AfterCommit`, for `BustTypeRegistry`'s
  reason: a bust before COMMIT can be undone by a reader re-caching the old
  schema, and a field-sync import runs every write inside one transaction.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, &bust/2)
  end

  defp bust(_changeset, {:ok, record} = result) do
    KilnCMS.AfterCommit.run(fn -> KilnCMS.Cache.bust_type_registry(record.org_id) end)
    result
  end

  # A failed write changed nothing, so there is nothing to invalidate.
  defp bust(_changeset, other), do: other
end
