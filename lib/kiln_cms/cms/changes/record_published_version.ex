defmodule KilnCMS.CMS.Changes.RecordPublishedVersion do
  @moduledoc """
  After a publish transition, points `published_version_id` at the immutable
  PaperTrail snapshot created for that action.

  Runs in `after_transaction` so the PaperTrail version row exists before we
  look it up. The live record remains the editable source of truth; the
  referenced version is the frozen public snapshot auditors can diff against.

  The pointer is written as `KilnCMS.CMS.Bookkeeping.system/0` (#1659), which
  the content policy admits to `:set_published_version_id` alone: the publish
  that triggers it may be the AshOban scheduler's, with no person behind it.
  """
  use Ash.Resource.Change

  require Ash.Query

  @publish_actions [:publish, :publish_scheduled, :publish_changes]

  @impl true
  def change(changeset, _opts, context) do
    actor_id = actor_id(context.actor)

    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      case result do
        {:ok, record} -> wire_version(record, actor_id)
        error -> error
      end
    end)
  end

  # Only a person has an id to attribute. `%KilnCMS.SystemActor{}` (#1402) has
  # no `:id`, so `context.actor.id` would raise a `KeyError` while the changeset
  # is built and fail the publish — see `KilnCMS.CMS.Changes.AnchorVersion`.
  defp actor_id(%{id: id}), do: id
  defp actor_id(_actor), do: nil

  defp wire_version(record, actor_id) do
    version_module = Module.concat(record.__struct__, Version)

    result =
      case latest_publish_version(version_module, record.id, record.org_id) do
        {:ok, %{} = version} ->
          Ash.update(record, %{published_version_id: version.id},
            action: :set_published_version_id,
            actor: KilnCMS.CMS.Bookkeeping.system(),
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

  # The read bypasses the policies (#1402's version-history argument): version
  # rows ARE the editorial history, and a `SystemActor` read grant on them would
  # hand every system caller all of it. This reads one row — the publish
  # version PaperTrail wrote for this very action — and only its id leaves here.
  # It cannot be refused, so it cannot answer "no version" and leave the pointer
  # stale.
  defp latest_publish_version(version_module, source_id, org_id) do
    version_module
    |> Ash.Query.filter(
      version_source_id == ^source_id and version_action_name in ^@publish_actions
    )
    |> Ash.Query.sort(version_inserted_at: :desc)
    |> Ash.Query.limit(1)
    # authorize?: false — one version row, tenant-scoped; no standing system
    # grant over the editorial history, and it cannot be refused into "none".
    |> Ash.read_one(authorize?: false, tenant: org_id)
  end
end
