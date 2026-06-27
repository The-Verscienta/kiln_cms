defmodule KilnCMS.Storage.S3.ReqClient do
  @moduledoc """
  `ExAws.Request.HttpClient` implementation backed by `Req`.

  Keeps the project on a single HTTP client (Req is already used for outbound
  webhooks) instead of pulling in hackney.

  Calls are bounded by connect/receive timeouts (#222) so a slow or stalled S3
  request can't hang an Oban variant worker, a LiveView upload, or a media load
  indefinitely. Both are configurable, and extra Req options can be injected:

      config :kiln_cms, KilnCMS.Storage.S3,
        connect_timeout_ms: 5_000,
        receive_timeout_ms: 30_000,
        req_options: [...]

  `req_options` is applied last (the test env uses it to route requests through a
  `Req.Test` stub), so it can override the defaults if needed.
  """
  @behaviour ExAws.Request.HttpClient

  @default_connect_timeout_ms 5_000
  @default_receive_timeout_ms 30_000

  @impl true
  def request(method, url, body, headers, http_opts) do
    case Req.request(Req.new(build_options(method, url, body, headers, http_opts))) do
      {:ok, response} ->
        {:ok,
         %{
           status_code: response.status,
           headers: Req.get_headers_list(response),
           body: response.body
         }}

      {:error, reason} ->
        {:error, %{reason: reason}}
    end
  end

  # Build the Req options, including bounded connect/receive timeouts (#222).
  # Public for testing that the timeouts are always present.
  @doc false
  def build_options(method, url, body, headers, _http_opts) do
    config = Application.get_env(:kiln_cms, KilnCMS.Storage.S3, [])

    [method: method, url: url, body: body, headers: headers, decode_body: false, retry: false]
    |> Keyword.merge(
      connect_options: [
        timeout: Keyword.get(config, :connect_timeout_ms, @default_connect_timeout_ms)
      ],
      receive_timeout: Keyword.get(config, :receive_timeout_ms, @default_receive_timeout_ms)
    )
    |> Keyword.merge(Keyword.get(config, :req_options, []))
  end
end
