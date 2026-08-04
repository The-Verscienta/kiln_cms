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

  ## Which is why `:max_redirects` follows them here, by hand

  Some callers have to follow one — a link checker (#474) that reported every
  `http://` URL as a 301 would report the whole web as moved. `redirect: false`
  still stands: each hop is a **fresh `request/3`**, so the `Location` is
  re-validated and re-pinned exactly like the URL the caller passed. Handing the
  chain to Req instead would resolve hops 2..n inside the client, past every
  check this module exists to make, and one open redirect on a trusted host
  would be a straight path back to the metadata service.

  Default `0` — nothing follows a redirect unless it asks to. A response that is
  *still* a 3xx when the hops run out comes back as that 3xx rather than an
  error, so a caller can tell "redirect chain too long" from "refused to dial".

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

  # A hard ceiling on `:max_redirects` regardless of what a caller asks for.
  # Every hop is a full validate-resolve-connect, so the option is also a
  # multiplier on how long one call can occupy a worker.
  @max_redirect_hops 10

  @redirect_statuses [301, 302, 303, 307, 308]

  @type option ::
          {:max_bytes, pos_integer()}
          | {:connect_timeout, pos_integer()}
          | {:receive_timeout, pos_integer()}
          | {:headers, [{String.t(), String.t()}]}
          | {:body, iodata()}
          | {:max_redirects, non_neg_integer()}
          | {:truncate_body, boolean()}
          | {:req_options, keyword()}

  @type response :: %{status: integer(), headers: map(), body: binary()}

  @doc """
  `GET` `url`, refusing anything `SafeUrl` will not vouch for.

  `{:ok, %{status: integer(), headers: map(), body: binary()}}`, or
  `{:error, reason}` — a blocked address, a transport failure, or a body over
  `:max_bytes`.

  Options: `:max_bytes` (default 256KB), `:connect_timeout` (5s),
  `:receive_timeout` (10s), `:headers`, `:max_redirects` (default 0 — see the
  moduledoc), `:truncate_body` (default false — when true an over-length body
  is cut at the cap and returned as an ordinary response instead of an error,
  for callers that only want the status), and `:req_options` (merged last, so a
  test env can point the request at a `Req.Test` stub).
  """
  @spec get(String.t(), [option()]) :: {:ok, response()} | {:error, String.t()}
  def get(url, opts \\ []), do: request(:get, url, opts)

  @doc """
  `HEAD` `url`, under the same pinning, redirect and byte-cap rules as `get/2`.

  For asking whether a URL is *there* without paying for what is at it. Note
  that plenty of servers answer HEAD with 405 or lie about it — a caller that
  cares (`KilnCMS.Links.External`) retries with `get/2` rather than believing
  the refusal.

  The byte cap still applies: a server is free to send a body on a HEAD
  response, and "we did not ask for one" is not a bound.
  """
  @spec head(String.t(), [option()]) :: {:ok, response()} | {:error, String.t()}
  def head(url, opts \\ []), do: request(:head, url, opts)

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
    hops = opts |> Keyword.get(:max_redirects, 0) |> clamp_hops()
    follow(method, url, opts, hops, [])
  end

  defp request(_method, _url, _opts), do: {:error, "blocked URL: must be a valid URL with a host"}

  defp clamp_hops(hops) when is_integer(hops) and hops > 0, do: min(hops, @max_redirect_hops)
  defp clamp_hops(_hops), do: 0

  # One hop. `visited` is a plain list because it is bounded by
  # `@max_redirect_hops` — a set would buy nothing and costs an opaque type.
  defp follow(method, url, opts, hops_left, visited) do
    case SafeUrl.resolve_pinned(url) do
      {:ok, pinned_ip} ->
        method
        |> dispatch(url, pinned_ip, opts)
        |> maybe_follow(method, url, opts, hops_left, visited)

      {:error, reason} ->
        {:error, blocked_message(reason, visited)}
    end
  end

  # A refusal on hop 2+ names the URL, because the one the caller passed was
  # fine and "blocked URL: must not target private addresses" about a link that
  # plainly is not private reads as a bug in the checker.
  defp blocked_message(reason, []), do: "blocked URL: #{reason}"

  defp blocked_message(reason, [previous | _rest]),
    do: "blocked redirect from #{previous}: #{reason}"

  defp maybe_follow({:ok, %{status: status} = response}, method, url, opts, hops_left, visited)
       when status in @redirect_statuses and hops_left > 0 do
    case next_url(response, url, [url | visited]) do
      nil ->
        {:ok, response}

      next ->
        {next_method, next_opts} = redirect_request(method, status, opts)
        next_opts = strip_credentials_across_hosts(next_opts, url, next)
        follow(next_method, next, next_opts, hops_left - 1, [url | visited])
    end
  end

  defp maybe_follow(result, _method, _url, _opts, _hops_left, _visited), do: result

  # A `Location` may be relative, so it is merged against the URL that produced
  # it. An already-seen URL ends the chase and the 3xx is returned as the
  # answer: a redirect loop is a fact about the link, not a transport failure.
  defp next_url(response, url, visited) do
    with [location | _rest] <- Map.get(response.headers, "location", []),
         merged when is_binary(merged) <- merge_location(url, location),
         false <- merged in visited do
      merged
    else
      _other -> nil
    end
  end

  defp merge_location(url, location) do
    location = String.trim(to_string(location))

    if location == "" do
      nil
    else
      case URI.merge(URI.parse(url), location) do
        %URI{host: host} = merged when is_binary(host) -> URI.to_string(merged)
        _other -> nil
      end
    end
  end

  # RFC 9110: 303 (and, in practice, 301/302) turn a POST into a GET, and the
  # body goes with it — replaying it against a target the author did not choose
  # is how a redirect becomes a request forgery. HEAD survives every hop,
  # including 303, which is exactly what a link check wants.
  defp redirect_request(:head, _status, opts), do: {:head, opts}

  defp redirect_request(method, status, opts) when method != :get and status in [301, 302, 303],
    do: {:get, Keyword.delete(opts, :body)}

  defp redirect_request(method, _status, opts), do: {method, opts}

  # Headers the caller set for *its* target, dropped when the target changes.
  # Nothing following redirects today sends either, but the cost of being wrong
  # about that later is handing a webhook signing header or a session cookie to
  # whoever controls a `Location` — and the caller that adds the header is not
  # the one that reads this module.
  @credential_headers ~w(authorization cookie proxy-authorization)

  defp strip_credentials_across_hosts(opts, from_url, to_url) do
    if URI.parse(from_url).host == URI.parse(to_url).host,
      do: opts,
      else: Keyword.update(opts, :headers, [], fn headers -> drop_credentials(headers) end)
  end

  defp drop_credentials(headers) do
    Enum.reject(headers, fn {name, _value} ->
      String.downcase(to_string(name)) in @credential_headers
    end)
  end

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
        collector_option(max_bytes, Keyword.get(opts, :truncate_body, false)) ++
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

  defp collector_option(max_bytes, truncate?), do: [into: collector(max_bytes, truncate?)]

  # Streams the body, aborting the moment it passes `max_bytes` rather than
  # buffering first and checking after — the check has to happen while the bytes
  # are still arriving or it has already cost the memory it exists to bound.
  #
  # `truncate?` decides what an abort *means*. By default it is an error: a
  # caller that asked for a document and got the first 256KB of one has nothing
  # it can parse. A caller that only wants the status line (a link checker) sets
  # `truncate_body: true` and gets an ordinary response holding the prefix —
  # without it, "this page is large" would be indistinguishable from "this page
  # is gone", and every long article on the web would read as a broken link.
  defp collector(max_bytes, truncate?) do
    fn {:data, data}, {req, resp} ->
      acc = resp.body || ""

      case acc do
        {:too_large, _limit} = marker ->
          {:halt, {req, %{resp | body: marker}}}

        acc when byte_size(acc) + byte_size(data) > max_bytes and truncate? ->
          {:halt, {req, %{resp | body: binary_part(acc <> data, 0, max_bytes)}}}

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
