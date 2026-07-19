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
  def change(changeset, _opts, context) do
    actor_id = context.actor && context.actor.id

    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      case result do
        {:ok, record} -> wire_version(record, actor_id)
        error -> error
      end
    end)
  end

  defp wire_version(record, actor_id) do
    version_module = Module.concat(record.__struct__, Version)

    result =
      case latest_publish_version(version_module, record.id, record.org_id) do
        {:ok, %{} = version} ->
          Ash.update(record, %{published_version_id: version.id},
            action: :set_published_version_id,
            authorize?: false,
            tenant: record.org_id
          )

        _ ->
          {:ok, record}
      end

    # Tamper-evident history anchor (#356): fold + sign the full version chain
    # at this publish point. `anchor/2` is config-gated and never raises, so a
    # chain problem can't break the publish.
    with {:ok, published} <- result,
         do: KilnCMS.Governance.Chain.anchor(published, actor_id: actor_id)

    result
  end

  defp latest_publish_version(version_module, source_id, org_id) do
    version_module
    |> Ash.Query.filter(
      version_source_id == ^source_id and version_action_name in ^@publish_actions
    )
    |> Ash.Query.sort(version_inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false, tenant: org_id)
  end
end
