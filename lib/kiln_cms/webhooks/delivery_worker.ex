defmodule KilnCMS.Webhooks.DeliveryWorker do
  @moduledoc """
  Delivers a single webhook: POSTs the signed JSON payload to one endpoint.
  Retried with backoff by Oban; non-2xx responses and transport errors fail the
  job so it retries. A deleted/inactive endpoint is a no-op (job succeeds).
  """
  use Oban.Worker, queue: :default, max_attempts: 5

  alias KilnCMS.CMS
  alias KilnCMS.Webhooks

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"endpoint_id" => id, "event" => event, "payload" => payload}}) do
    case CMS.get_webhook_endpoint(id, authorize?: false) do
      {:ok, %{active: true} = endpoint} -> deliver(endpoint, event, payload)
      _ -> :ok
    end
  end

  defp deliver(endpoint, event, payload) do
    body = Jason.encode!(%{event: event, data: payload})

    headers = [
      {"content-type", "application/json"},
      {Webhooks.signature_header(), Webhooks.signature(endpoint.secret, body)},
      {Webhooks.event_header(), event}
    ]

    options =
      [url: endpoint.url, method: :post, body: body, headers: headers, retry: false] ++
        Webhooks.req_options()

    case Req.request(Req.new(options)) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, "endpoint returned HTTP #{status}"}
      {:error, reason} -> {:error, "delivery failed: #{inspect(reason)}"}
    end
  end
end
