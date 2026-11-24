defmodule KilnCMS.Billing.Changes.ReportWebhookEventGivenUp do
  @moduledoc """
  Says that the sweeper gave up on a provider webhook event (#3159):
  `KilnCMS.Billing.WebhookEvent`'s `:give_up` logs at `:error` and emits
  `[:kiln_cms, :billing, :webhook_event, :gave_up]` with `%{count: 1}`, so an
  event that will never be applied shows on a dashboard and not only as a
  `gave_up_at` stamp.

  The metadata is `webhook_event_id` (the row), `event_id` (the provider's
  id, which the provider's dashboard searches by), `type` and
  `redrive_count` (`nil` for a row recorded before the sweeper, which is given
  up on without a redrive). No payload: it carries customer data.

  From `after_transaction/2` on a committed stamp only, and once per give-up:
  the trigger never picks a stamped row up again until a provider resend
  claims it. Implements `atomic/3` because `:give_up` is atomic; it writes no
  attribute.
  """
  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, event} = result ->
        report(event)
        result

      _changeset, result ->
        result
    end)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp report(event) do
    Logger.error(
      "billing webhook #{event.provider_event_id} (#{event.type}) was never processed and " <>
        "will not be retried (#{redrives(event.redrive_count)}). Fix the cause, then " <>
        "resend the event from the provider's dashboard."
    )

    :telemetry.execute([:kiln_cms, :billing, :webhook_event, :gave_up], %{count: 1}, %{
      webhook_event_id: event.id,
      event_id: event.provider_event_id,
      type: event.type,
      redrive_count: event.redrive_count
    })
  end

  defp redrives(nil), do: "recorded before the sweeper, so not replayed"
  defp redrives(count), do: "re-enqueued #{count} times"
end
