defmodule KilnCMS.Webhooks.DeliveryWorker do
  @moduledoc """
  Delivers a single webhook: POSTs the signed JSON payload to one endpoint.
  Retried with backoff by Oban; non-2xx responses and transport errors fail the
  job so it retries. A deleted/inactive endpoint is a no-op (job succeeds).
  """
  use Oban.Worker, queue: :webhooks, max_attempts: 5

  alias KilnCMS.CMS
  alias KilnCMS.Webhooks
  alias KilnCMS.Webhooks.SafeUrl

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"endpoint_id" => id, "event" => event, "payload" => payload}}) do
    case CMS.get_webhook_endpoint(id, authorize?: false) do
      {:ok, %{active: true} = endpoint} -> deliver(endpoint, event, payload)
      _ -> :ok
    end
  end

  defp deliver(endpoint, event, payload) do
    # Resolve + validate in one step and pin the resulting address. Connecting to
    # the pinned IP (below) stops Req from re-resolving the host at connect time,
    # which would otherwise reopen a DNS-rebinding / TOCTOU SSRF window.
    case SafeUrl.resolve_pinned(endpoint.url) do
      {:ok, pinned_ip} -> post_delivery(endpoint, event, payload, pinned_ip)
      {:error, reason} -> {:error, "blocked webhook URL: #{reason}"}
    end
  end

  defp post_delivery(endpoint, event, payload, pinned_ip) do
    body = Jason.encode!(%{event: event, data: payload})

    headers =
      [
        {"content-type", "application/json"},
        {Webhooks.signature_header(), Webhooks.signature(endpoint.secret, body)},
        {Webhooks.event_header(), event}
      ] ++ host_header(endpoint.url, pinned_ip)

    options =
      [
        method: :post,
        body: body,
        headers: headers,
        retry: false,
        redirect: false,
        # Bound how long a slow/hanging endpoint can hold this Oban worker (queue
        # concurrency is limited). req_options() is appended after, so the test
        # env can still override these.
        receive_timeout: 15_000
      ] ++
        connect_target(endpoint.url, pinned_ip) ++
        Webhooks.req_options()

    case Req.request(Req.new(options)) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, "endpoint returned HTTP #{status}"}
      {:error, reason} -> {:error, "delivery failed: #{inspect(reason)}"}
    end
  end

  # Build the `url:` + `connect_options:` that pin the connection to the address
  # `SafeUrl` already validated. We rewrite the URL host to the literal IP and
  # (for HTTPS) point SNI + certificate hostname verification back at the
  # original hostname so TLS still validates against the real name, not the IP.
  # The original `Host` header is restored separately (see `host_header/2`).
  #
  # When `pinned_ip` is `nil` (DNS resolution disabled — test env), fall back to
  # the original URL so the `Req.Test` stub still matches by host.
  defp connect_target(url, nil) do
    [url: url, connect_options: [timeout: 5_000]]
  end

  defp connect_target(url, pinned_ip) do
    uri = URI.parse(url)
    ip_string = pinned_ip |> :inet.ntoa() |> to_string()

    url_host =
      case tuple_size(pinned_ip) do
        8 -> "[#{ip_string}]"
        _ -> ip_string
      end

    connect_options =
      if uri.scheme == "https" do
        [
          timeout: 5_000,
          transport_opts: [
            verify: :verify_peer,
            cacerts: :public_key.cacerts_get(),
            server_name_indication: String.to_charlist(uri.host),
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ]
          ]
        ]
      else
        [timeout: 5_000]
      end

    [url: URI.to_string(%{uri | host: url_host}), connect_options: connect_options]
  end

  # When pinning to an IP, the URL host is the literal address, so restore the
  # real `Host` header (with non-default port) for the receiving server / vhost.
  # No override is needed when not pinning — Req derives `Host` from the URL.
  defp host_header(_url, nil), do: []

  defp host_header(url, _pinned_ip) do
    uri = URI.parse(url)

    value =
      cond do
        is_nil(uri.port) ->
          uri.host

        (uri.scheme == "https" and uri.port == 443) or (uri.scheme == "http" and uri.port == 80) ->
          uri.host

        true ->
          "#{uri.host}:#{uri.port}"
      end

    [{"host", value}]
  end
end
