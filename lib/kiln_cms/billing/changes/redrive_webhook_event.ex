defmodule KilnCMS.Billing.Changes.RedriveWebhookEvent do
  @moduledoc """
  Re-enqueues a stranded provider webhook event (#3159): the second half of
  `KilnCMS.Billing.WebhookEvent`'s `:redrive`, which the sweeper's trigger runs.

  The job is inserted in an `after_action`, inside the update's transaction,
  as `:receive` does: a failed enqueue rolls the count back and the trigger's
  job retries. A unique conflict comes back `{:ok, job}` from
  `KilnCMS.Billing.WebhookWorker.enqueue/1` and counts as queued. Once the write
  commits, a warning says which event went round again and how many times.

  It implements `atomic/3` as well as `change/3`, because `:redrive` is atomic
  (its filter and the count increment are in the `UPDATE`). It writes no
  attribute, so the atomic form is the same change.
  """
  use Ash.Resource.Change

  require Logger

  alias KilnCMS.Billing.WebhookWorker

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.after_action(fn _changeset, event ->
      case WebhookWorker.enqueue(event) do
        {:ok, _job} -> {:ok, event}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> Ash.Changeset.after_transaction(fn
      _changeset, {:ok, event} = result ->
        Logger.warning(
          "billing webhook #{event.provider_event_id} (#{event.type}) had no job to " <>
            "process it; re-enqueued (#{event.redrive_count} of #{max_redrives()})"
        )

        result

      _changeset, result ->
        result
    end)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp max_redrives, do: KilnCMS.Billing.WebhookEvent.max_redrives()
end
