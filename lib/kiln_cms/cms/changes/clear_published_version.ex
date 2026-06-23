defmodule KilnCMS.CMS.Changes.ClearPublishedVersion do
  @moduledoc """
  Clears `published_version_id` when content is unpublished.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      case Ash.update(record, %{published_version_id: nil},
             action: :set_published_version_id,
             authorize?: false
           ) do
        {:ok, updated} -> {:ok, updated}
        {:error, error} -> {:error, error}
      end
    end)
  end
end
