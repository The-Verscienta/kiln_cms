defmodule KilnCMS.Webhooks do
  @moduledoc """
  Outbound webhook dispatch.

  When content is published, `dispatch/2` enqueues one `DeliveryWorker` Oban
  job per active, subscribed endpoint. Deliveries are signed with HMAC-SHA256
  over the request body using the endpoint's secret, so receivers can verify
  authenticity.
  """
  alias KilnCMS.CMS
  alias KilnCMS.Webhooks.DeliveryWorker

  @signature_header "x-kilncms-signature"
  @event_header "x-kilncms-event"

  def signature_header, do: @signature_header
  def event_header, do: @event_header

  @doc "Lowercase hex HMAC-SHA256 of `body` keyed by `secret`."
  @spec signature(String.t(), iodata()) :: String.t()
  def signature(secret, body) do
    :hmac |> :crypto.mac(:sha256, secret, body) |> Base.encode16(case: :lower)
  end

  @doc """
  Enqueue a delivery job for every active endpoint subscribed to `event`.
  Reads endpoints as a system job (`authorize?: false`).
  """
  @spec dispatch(String.t(), map()) :: :ok
  def dispatch(event, payload) do
    CMS.list_webhook_endpoints!(authorize?: false)
    |> Enum.filter(&(&1.active && event in &1.events))
    |> Enum.each(fn endpoint ->
      %{endpoint_id: endpoint.id, event: event, payload: payload}
      |> DeliveryWorker.new()
      |> Oban.insert!()
    end)
  end

  @doc false
  # Extra Req options (e.g. a `Req.Test` plug in the test env).
  def req_options,
    do: Keyword.get(Application.get_env(:kiln_cms, __MODULE__, []), :req_options, [])
end
