defmodule KilnCMS.CMS.Changes.RecordPublishedVersion do
  @moduledoc """
  After a publish transition, points `published_version_id` at the immutable
  PaperTrail snapshot created for that action.

  Runs in `after_transaction` so the PaperTrail version row exists before we
  look it up. The live record remains the editable source of truth; the
  referenced version is the frozen public snapshot auditors can diff against.
  """
  use Ash.Resource.Change

  require Ash.Query

  @publish_actions [:publish, :publish_scheduled]

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      case result do
        {:ok, record} -> wire_version(record)
        error -> error
      end
    end)
  end

  defp wire_version(record) do
    version_module = Module.concat(record.__struct__, Version)

    case latest_publish_version(version_module, record.id) do
      {:ok, %{} = version} ->
        Ash.update(record, %{published_version_id: version.id},
          action: :set_published_version_id,
          authorize?: false
        )

      _ ->
        {:ok, record}
    end
  end

  defp latest_publish_version(version_module, source_id) do
    version_module
    |> Ash.Query.filter(
      version_source_id == ^source_id and version_action_name in ^@publish_actions
    )
    |> Ash.Query.sort(version_inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false)
  end
end
