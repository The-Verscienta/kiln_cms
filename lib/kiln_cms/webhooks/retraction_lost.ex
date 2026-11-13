defmodule KilnCMS.Webhooks.RetractionLost do
  @moduledoc """
  What happens when a retraction delivery exhausts its retries (#1926).

  An `unpublished`, `archived` or `deleted` webhook that never got through
  means a consumer may still be serving a document the site has withdrawn. A
  `:failed` row in the delivery ledger is true but silent: nobody reads the
  ledger until they already suspect something. So an exhausted retraction is
  surfaced in two places:

    * **a console notice** — a `:retraction_lost` in-app notification to every
      admin of the document's site (`KilnCMS.Accounts.Scoping.users_with_tier/2`),
      which the bell and `/editor/inbox` show and which links to the
      document's governance trail. Not subject to a per-user preference: this
      is the one delivery the site promised would not be dropped, and muting
      the news that it was is not a choice the notice offers. Skipped
      (`notify?: false`) for an endpoint that has been auto-disabled past
      `KilnCMS.Webhooks.retraction_stale_after_days/0`, so a bulk archive
      against a long-dead receiver is not a notice per document;
    * **the document's governance trail** — `KilnCMS.Governance.trail/3` lists
      the failed delivery (`KilnCMS.Webhooks.lost_retractions/3`), with the
      endpoint, the error and, once a replay gets through, when it did.

  Best-effort like every notifier: the delivery has already failed, and a
  notice that cannot be written is logged rather than raised into the worker,
  where a raise would only make Oban retry a job whose outcome is settled.
  """
  require Logger

  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.Notifications

  @doc """
  Surface `delivery` — a retraction that has just been settled `:failed` with
  `reason` — to the site's admins. Always logs; `:ok` either way. With
  `notify?: false` it only logs: the trail row is the ledger row itself.
  """
  @spec surface(struct(), String.t(), keyword()) :: :ok
  def surface(delivery, reason, opts \\ []) do
    Logger.error(
      "Retraction webhook #{delivery.event} (delivery #{delivery.id}) to " <>
        "#{endpoint_url(delivery)} exhausted its retries: #{reason}"
    )

    case Keyword.get(opts, :notify?, true) && subject(delivery) do
      false ->
        :ok

      {:ok, subject} ->
        delivery.org_id
        |> Scoping.users_with_tier([:admin])
        |> Enum.each(&notify(&1, subject, delivery, reason))

      :error ->
        Logger.error(
          "Retraction webhook delivery #{delivery.id} names no document; " <>
            "no console notice written"
        )
    end

    :ok
  rescue
    error ->
      Logger.error(
        "Retraction webhook delivery #{delivery.id}: notice not recorded: " <>
          Exception.message(error)
      )

      :ok
  end

  defp notify(user, subject, delivery, reason) do
    Notifications.record_in_app(%{
      user_id: user.id,
      org_id: delivery.org_id,
      event: :retraction_lost,
      content_type: subject.type,
      content_id: subject.id,
      block_id: nil,
      title: subject.title,
      excerpt: excerpt(delivery, reason),
      actor_id: nil,
      actor_name: nil
    })
  end

  # The document the retraction was about: the event's namespace and the id
  # its payload carried. Full payloads (`unpublished`) carry a title; the
  # identity-only tombstones (`archived`, `deleted`) carry the slug.
  defp subject(%{event: event, payload: payload}) do
    with {type, _verb} <- KilnCMS.CMS.WebhookEndpoint.event_parts(event),
         id when is_binary(id) and id != "" <- field(payload, "id") do
      {:ok, %{type: type, id: id, title: title(payload, id)}}
    else
      _ -> :error
    end
  end

  defp title(payload, id) do
    Enum.find_value(["title", "slug"], id, fn key ->
      case field(payload, key) do
        value when is_binary(value) and value != "" -> String.slice(value, 0, 200)
        _ -> nil
      end
    end)
  end

  # A payload read back from the ledger has string keys; one handed straight
  # from a dispatch may still have atom keys.
  defp field(payload, key) when is_map(payload) do
    case Map.fetch(payload, key) do
      {:ok, value} -> value
      :error -> Map.get(payload, String.to_existing_atom(key))
    end
  end

  defp field(_payload, _key), do: nil

  defp excerpt(delivery, reason),
    do: String.slice("#{endpoint_url(delivery)} — #{reason}", 0, 500)

  # Masked (#2245): the log line and the notice every admin of the site reads
  # name the endpoint without handing out its URL, which for an incoming
  # webhook is the credential.
  defp endpoint_url(%{endpoint: %{url: url}}) when is_binary(url),
    do: KilnCMS.Webhooks.display_url(url)

  defp endpoint_url(%{endpoint_url: url}) when is_binary(url),
    do: KilnCMS.Webhooks.display_url(url)

  defp endpoint_url(_delivery), do: "a deleted endpoint"
end
