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

  ## A site's own store (#1559)

  A request built from a site's profile (`KilnCMS.Storage.SiteProfiles`) says
  so in its `http_opts` (`site_storage: true`), with the address its endpoint
  was resolved to (`pinned_address:`). Such a request connects to that
  address, not to whatever the name resolves to by now, with SNI and
  certificate verification pointed back at the name — `KilnCMS.SafeFetch`'s
  pinning, reused rather than restated. The signed `host` header ExAws already
  put on the request is what the store sees, so the signature still matches.
  And it follows no redirect: a redirect is a fresh resolution the pin never
  sees, and a store has no reason to send one.
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
  def build_options(method, url, body, headers, http_opts) do
    config = Application.get_env(:kiln_cms, KilnCMS.Storage.S3, [])
    connect_timeout = Keyword.get(config, :connect_timeout_ms, @default_connect_timeout_ms)

    [method: method, url: url, body: body, headers: headers, decode_body: false, retry: false]
    |> Keyword.merge(
      connect_options: [timeout: connect_timeout],
      receive_timeout: Keyword.get(config, :receive_timeout_ms, @default_receive_timeout_ms)
    )
    |> Keyword.merge(site_options(url, http_opts, connect_timeout))
    |> Keyword.merge(Keyword.get(config, :req_options, []))
  end

  # See "A site's own store" above. `pinned_address: nil` is the not-pinning
  # case (`allow_private_hosts`, or DNS resolution off in the test env): the URL
  # as given, still without redirects.
  defp site_options(url, http_opts, connect_timeout) when is_list(http_opts) do
    if Keyword.get(http_opts, :site_storage) == true do
      url
      |> KilnCMS.SafeFetch.connect_target(
        Keyword.get(http_opts, :pinned_address),
        connect_timeout
      )
      |> Keyword.put(:redirect, false)
    else
      []
    end
  end

  defp site_options(_url, _http_opts, _connect_timeout), do: []
end
