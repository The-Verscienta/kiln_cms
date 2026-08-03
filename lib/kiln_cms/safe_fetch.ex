defmodule KilnCMS.SafeFetch do
  @moduledoc """
  Outbound HTTP to a URL the *content* chose, rather than the operator (#489).

  `KilnCMS.Webhooks.SafeUrl` decides whether an address may be dialled at all.
  This is the other half: actually dialling it without giving back what that
  check just won.

  Derived from `KilnCMS.Webhooks.DeliveryWorker`, which had the only correct
  implementation, when the oEmbed resolver (#489) needed a second one. The
  pinning dance below is about fifteen lines of TLS options that are wrong in a
  way nothing tests for if you retype them — SNI pointed at an IP still
  *connects*, it just stops verifying the hostname.

  **`DeliveryWorker` has not been moved onto this yet**, so there are currently
  two copies and the next TLS-option edit will touch one. That, and this
  module's own missing tests, are tracked in #753. Do not read the paragraph
  above as "the duplication is gone".

  ## Why the address is pinned

  Validating a hostname and then handing that hostname to an HTTP client
  re-resolves it at connect time, which is a DNS-rebinding / TOCTOU hole: an
  attacker controlling the name answers with a public address during validation
  and `169.254.169.254` a millisecond later. So the address is resolved once,
  checked, and *connected to as a literal* — with SNI and certificate hostname
  verification pointed back at the real name so TLS still validates against it,
  and the original `Host` header restored for the receiving vhost.

  `redirect: false` is load-bearing for the same reason: a followed redirect is
  a fresh resolution the pin never sees.

  ## Why there is a byte cap

  The response is attacker-influenced in both content *and length*. Without a
  cap, one URL pointing at an endless stream is an out-of-memory kill for
  whatever process is fetching — a LiveView, an Oban worker with a bounded
  queue. `:max_bytes` is enforced by streaming and aborting, not by trusting
  `content-length`, which the far end writes.
  """

  alias KilnCMS.Webhooks.SafeUrl

  @default_max_bytes 256 * 1024
  @default_connect_timeout 5_000
  @default_receive_timeout 10_000

  @type option ::
          {:max_bytes, pos_integer()}
          | {:connect_timeout, pos_integer()}
          | {:receive_timeout, pos_integer()}
          | {:headers, [{String.t(), String.t()}]}
          | {:body, iodata()}
          | {:req_options, keyword()}

  @type response :: %{status: integer(), headers: map(), body: binary()}

  @doc """
  `GET` `url`, refusing anything `SafeUrl` will not vouch for.

  `{:ok, %{status: integer(), headers: map(), body: binary()}}`, or
  `{:error, reason}` — a blocked address, a transport failure, or a body over
  `:max_bytes`.

  Options: `:max_bytes` (default 256KB), `:connect_timeout` (5s),
  `:receive_timeout` (10s), `:headers`, and `:req_options` (merged last, so a
  test env can point the request at a `Req.Test` stub).
  """
  @spec get(String.t(), [option()]) :: {:ok, response()} | {:error, String.t()}
  def get(url, opts \\ []), do: request(:get, url, opts)

  @doc """
  `POST` `body` to `url`, under the same pinning, redirect and byte-cap rules as
  `get/2`.

  The cap is **not** relaxed for a caller that ignores the response body: with
  no `into:` Req buffers the whole thing regardless of whether anyone reads it,
  so "we only look at the status" is not a reason to skip the bound — it is a
  reason nobody would notice the memory.
  """
  @spec post(String.t(), iodata(), [option()]) :: {:ok, response()} | {:error, String.t()}
  def post(url, body, opts \\ []), do: request(:post, url, Keyword.put(opts, :body, body))

  defp request(method, url, opts) when is_binary(url) do
    case SafeUrl.resolve_pinned(url) do
      {:ok, pinned_ip} -> dispatch(method, url, pinned_ip, opts)
      {:error, reason} -> {:error, "blocked URL: #{reason}"}
    end
  end

  defp request(_method, _url, _opts), do: {:error, "blocked URL: must be a valid URL with a host"}

  defp dispatch(method, url, pinned_ip, opts) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    options =
      [
        method: method,
        headers: Keyword.get(opts, :headers, []) ++ host_header(url, pinned_ip),
        retry: false,
        # See the moduledoc: a redirect is a re-resolution the pin never sees.
        redirect: false,
        # Bytes out, always. Req decodes JSON by content-type otherwise, which
        # makes `body` a map on some responses and a binary on others — and the
        # caller then has two shapes to handle for no gain, since decoding is
        # exactly the step that should happen *after* the size cap, under the
        # caller's own error handling.
        decode_body: false,
        receive_timeout: Keyword.get(opts, :receive_timeout, @default_receive_timeout)
      ] ++
        body_option(opts) ++
        collector_option(max_bytes) ++
        connect_target(
          url,
          pinned_ip,
          Keyword.get(opts, :connect_timeout, @default_connect_timeout)
        ) ++
        Keyword.get(opts, :req_options, [])

    case Req.request(Req.new(options)) do
      {:ok, %{status: status, headers: headers, body: body}} when is_binary(body) ->
        {:ok, %{status: status, headers: headers, body: body}}

      # The collector aborts by returning `{:halt, …}`; Req surfaces whatever the
      # accumulator held, so an over-length body arrives as the marker below.
      {:ok, %{body: {:too_large, limit}}} ->
        {:error, "response exceeded #{limit} bytes"}

      # `decode_body: false` means a binary in every ordinary case; iodata is
      # still possible from an adapter, and anything else is returned as an
      # error rather than coerced, because silently stringifying a surprise is
      # how a shape mismatch becomes a confusing bug two modules away.
      {:ok, %{status: status, headers: headers, body: body}} when is_list(body) ->
        {:ok, %{status: status, headers: headers, body: IO.iodata_to_binary(body)}}

      {:ok, %{body: body}} ->
        {:error, "unexpected response body: #{inspect(body, limit: 5)}"}

      {:error, reason} ->
        {:error, "request failed: #{inspect(reason)}"}
    end
  end

  defp body_option(opts) do
    case Keyword.fetch(opts, :body) do
      {:ok, body} -> [body: body]
      :error -> []
    end
  end

  defp collector_option(max_bytes), do: [into: collector(max_bytes)]

  # Streams the body, aborting the moment it passes `max_bytes` rather than
  # buffering first and checking after — the check has to happen while the bytes
  # are still arriving or it has already cost the memory it exists to bound.
  defp collector(max_bytes) do
    fn {:data, data}, {req, resp} ->
      acc = resp.body || ""

      case acc do
        {:too_large, _limit} = marker ->
          {:halt, {req, %{resp | body: marker}}}

        acc when byte_size(acc) + byte_size(data) > max_bytes ->
          {:halt, {req, %{resp | body: {:too_large, max_bytes}}}}

        acc ->
          {:cont, {req, %{resp | body: acc <> data}}}
      end
    end
  end

  # `url:` + `connect_options:` pinning the connection to the address `SafeUrl`
  # validated: the URL host becomes the literal address, and (for HTTPS) SNI and
  # certificate hostname verification are pointed back at the real hostname so
  # TLS still validates against the name rather than the IP.
  #
  # `pinned_ip` is `nil` when DNS resolution is disabled (test env) — fall back
  # to the original URL so a `Req.Test` stub still matches by host.
  defp connect_target(url, nil, timeout), do: [url: url, connect_options: [timeout: timeout]]

  defp connect_target(url, pinned_ip, timeout) do
    uri = URI.parse(url)
    ip_string = pinned_ip |> :inet.ntoa() |> to_string()
    url_host = if tuple_size(pinned_ip) == 8, do: "[#{ip_string}]", else: ip_string

    connect_options =
      if uri.scheme == "https" do
        [
          timeout: timeout,
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
        [timeout: timeout]
      end

    [url: URI.to_string(%{uri | host: url_host}), connect_options: connect_options]
  end

  # Pinning replaces the URL host with a literal, so the real `Host` has to be
  # restored for the receiving vhost. Not needed when not pinning — Req derives
  # it from the URL.
  defp host_header(_url, nil), do: []

  defp host_header(url, _pinned_ip) do
    uri = URI.parse(url)
    default_port = if uri.scheme == "https", do: 443, else: 80
    host = if uri.port in [nil, default_port], do: uri.host, else: "#{uri.host}:#{uri.port}"
    [{"host", host}]
  end
end
