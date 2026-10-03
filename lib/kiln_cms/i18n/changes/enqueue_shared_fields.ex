defmodule KilnCMS.I18n.Changes.EnqueueSharedFields do
  @moduledoc """
  After a locale variant publishes — or is edited while live — queue
  field-level localization's follow-up (#1327, `KilnCMS.I18n.SharedFieldsWorker`):
  the shared-value copy between variants and the re-fire of siblings that
  inherit from this one.

  Runs in `after_transaction`, on a committed published record only, and
  never fails the action: an enqueue failure is logged. Queues nothing for a
  type that declares no `:shared` or `:fallback` field, which is every type
  until a site opts one in — so the cost on a site that has not is one
  definitions read per publish.
  """
  use Ash.Resource.Change

  require Logger

  alias KilnCMS.I18n.FieldLocalization

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, %{state: :published} = record} = result ->
        maybe_enqueue(record)
        result

      _changeset, result ->
        result
    end)
  end

  defp maybe_enqueue(record) do
    definitions = FieldLocalization.definitions(record, KilnCMS.SystemActor.new(:localization))

    if FieldLocalization.any?(record, definitions) do
      case KilnCMS.I18n.SharedFieldsWorker.enqueue(record) do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          Logger.error("Enqueue shared-field sync failed for #{record.id}: #{inspect(reason)}")
      end
    end
  rescue
    error ->
      Logger.error("Shared-field sync check failed for #{record.id}: #{Exception.message(error)}")
  end
end
