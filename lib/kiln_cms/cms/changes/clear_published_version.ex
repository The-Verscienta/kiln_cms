defmodule KilnCMS.CMS.Changes.ClearPublishedVersion do
  @moduledoc """
  Clears `published_version_id` when content is unpublished.

  Written as `KilnCMS.CMS.Bookkeeping.system/0` (#1659), which the content
  policy admits to `:set_published_version_id` alone — the same actor
  `RecordPublishedVersion` sets the pointer with.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      # Tenant-strict (#419): carry the record's own org, mirroring
      # RecordPublishedVersion — without it the unpublish after_action raises
      # a tenant-required error under the strict build.
      case Ash.update(record, %{published_version_id: nil},
             action: :set_published_version_id,
             actor: KilnCMS.CMS.Bookkeeping.system(),
             tenant: record.org_id
           ) do
        {:ok, updated} -> {:ok, updated}
        {:error, error} -> {:error, error}
      end
    end)
  end
end
