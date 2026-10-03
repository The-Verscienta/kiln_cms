defmodule KilnCMSWeb.Plugs.ClientIp do
  @moduledoc """
  Rewrites `conn.remote_ip` to the real client IP parsed from the request's
  forwarding headers when it arrives through a **trusted** reverse proxy, so
  IP-based rate limiting (`KilnCMSWeb.Plugs.RateLimit`) keys on the client rather
  than the proxy address.

  Trusted proxy CIDRs come from `config :kiln_cms, :trusted_proxies` (set via the
  `TRUSTED_PROXIES` env var in `config/runtime.exs`). When none are configured
  this is a no-op and `remote_ip` stays the direct peer — the correct behaviour
  for an internet-facing deployment where `X-Forwarded-For` is attacker-spoofable.

  ## A platform's own client-address header (#1548)

  Fly.io, Railway and DigitalOcean App Platform document no address range for
  their proxies, so `TRUSTED_PROXIES` cannot be set there without guessing
  (and on App Platform `X-Forwarded-For` carries the ingress address, not the
  client's). Each proxy does write the client address into a header of its
  own: `Fly-Client-IP`, `X-Real-IP` (Railway) and `do-connecting-ip`.

  `CLIENT_IP_HEADER` names one of those three. It trusts a request header with
  no peer check, which is safe only where every request reaches the app
  through that platform's proxy, which sets or overwrites the header. So it is
  honoured only when the environment variables that platform's runtime sets
  are present too (`header_setting/1`); anywhere else it is refused, logged
  once, and the plug behaves as if it were unset. When honoured it takes
  precedence over `TRUSTED_PROXIES`; a request without the header (or with
  something other than one address in it) falls through to the proxy path.

  Sockets see only `x-` headers (see `resolve/2`), so Railway's `X-Real-IP`
  reaches a `/live` handshake but `Fly-Client-IP` and `do-connecting-ip` do
  not: there, socket buckets — including the `/sign-in` form's — stay keyed on
  the proxy's address, the coarse but safe direction.

  The plug wraps `RemoteIp` rather than using it directly because the endpoint
  builds plug `init/1` at compile time, while the proxy list is only known at
  runtime; options are therefore built lazily on first use and cached.

  ## The unset-behind-a-proxy trap (#564)

  Leaving `TRUSTED_PROXIES` unset is right when the app is internet-facing and
  wrong when it is not, and the two are indistinguishable from config alone.
  Behind a reverse proxy with it unset, every request carries the *proxy's*
  address, so every rate-limit bucket collapses into one counter for the
  entire internet:

    * **availability** — one noisy client exhausts the bucket for everyone;
      `:auth` is 40/min and `:form` is 20/min *in total*, across all users;
    * **security** — per-IP brute-force protection on `/api/auth/sign_in` and
      `/sign-in` stops being per-IP, so the control is not doing what the threat
      model says it does.

  Nothing errors, which is what makes it a trap: the deployment that most needs
  the control is exactly the one where it silently degrades. So the first time a
  request arrives carrying a forwarding header while no proxies are trusted, this
  logs a warning naming the variable — the request itself is the only reliable
  evidence that there is a proxy in front, which a boot-time check cannot have.

  The detection covers `RemoteIp`'s whole default header set, not just
  `X-Forwarded-For`: a proxy that sets only `X-Real-IP` or the RFC 7239
  `Forwarded:` collapses the buckets identically, so warning on one header alone
  would stay silent for exactly the deployments it exists to catch.

  Logged once per node in the steady state: a repeat every request would hand
  anyone who can set a header a log-volume amplifier, and this plug runs before
  the rate limiter. The latch is check-then-set without synchronisation, so
  requests already in flight when the first one warns may each log — bounded by
  concurrency, and not worth a lock (`:persistent_term.put/2` with an unchanged
  value is free, so the duplicates cost log lines and nothing else).
  """
  @behaviour Plug

  require Logger

  @warned_key {__MODULE__, :warned_untrusted_forwarding?}
  @bad_proxies_key {__MODULE__, :warned_bad_proxies?}

  # Read from `RemoteIp` rather than restated, so the detection cannot drift
  # below what is actually honoured: checking only `x-forwarded-for` would stay
  # silent for a proxy that sets `X-Real-IP` or the RFC 7239 `Forwarded:`, which
  # collapses the buckets just the same. A `remote_ip` bump that adds a header
  # widens this with it.
  @forwarding_headers RemoteIp.Options.default(:headers)

  @refused_header_key {__MODULE__, :warned_refused_header?}

  # The one-click platforms whose proxy puts the client address in a header of
  # its own (#1548), and the environment variables that platform's runtime sets
  # in every container. `CLIENT_IP_HEADER` is honoured only when ALL of that
  # platform's markers are present, so a value copied into a deployment
  # anywhere else — where any client could send the header and pick its own
  # rate-limit bucket — does nothing but log.
  #
  # Render is absent on purpose: it documents no such header. Its
  # `True-Client-IP` comes from the Cloudflare layer in front of it, which
  # Render does not promise to keep.
  @platform_headers %{
    # Set by Fly Proxy on every request it forwards; Fly sets both variables
    # in every Machine.
    "fly-client-ip" => {"Fly.io", ["FLY_APP_NAME", "FLY_MACHINE_ID"]},
    # Railway's edge sets X-Real-IP, overwriting a client's own; Railway sets
    # both variables in every deployment.
    "x-real-ip" => {"Railway", ["RAILWAY_SERVICE_ID", "RAILWAY_ENVIRONMENT_ID"]},
    # App Platform injects no variable of its own, so the marker is the
    # app-wide `${APP_ID}` binding, which only App Platform resolves.
    # `.do/app.yaml` binds it; `header_setting/1` also requires it to be a UUID,
    # so a hand-typed placeholder does not pass.
    "do-connecting-ip" => {"DigitalOcean App Platform", ["APP_ID"]}
  }

  @impl true
  def init(_opts), do: []

  @impl true
  def call(conn, _opts) do
    case from_platform_header(conn.req_headers) do
      nil -> call_proxies(conn)
      client -> %{conn | remote_ip: client}
    end
  end

  defp call_proxies(conn) do
    case proxies() do
      [] ->
        warn_once_if_forwarded(conn.req_headers)
        conn

      list ->
        case remote_ip_opts(list) do
          {:ok, opts} -> RemoteIp.call(conn, opts)
          :error -> conn
        end
    end
  end

  @doc """
  The client address for a connection that has no `Plug.Conn` — a socket
  handshake, whose `connect_info` carries `:peer_data` and `:x_headers` but
  nothing this plug can rewrite (#715).

  Same rule as `call/2` and deliberately so: with no trusted proxies the
  forwarding headers are spoofable and are ignored, so the peer address stands.
  Two copies of "when do we believe `X-Forwarded-For`" that drift would give the
  socket a different client identity than the HTTP request that preceded it, and
  the whole point of sharing a bucket is that they agree.

  One narrowing worth knowing: `Phoenix.LiveView`'s `:x_headers` is exactly the
  headers whose name starts with `x-`, so the RFC 7239 `Forwarded:` header —
  which `RemoteIp` honours over HTTP — cannot reach here. A deployment behind a
  proxy that sets *only* `Forwarded:` therefore keys socket buckets on the proxy
  address. That is the safe direction (a bucket too coarse, never one attributed
  to a spoofed address), and it is the transport's limit, not a choice made here.

  Returns `nil` only when the caller has neither — which the endpoint's
  `connect_info` makes impossible for `/live`, so a `nil` means the transport
  was reconfigured and callers should treat it as one unknown client rather than
  as "no limit applies".
  """
  @spec resolve([{String.t(), String.t()}], :inet.ip_address() | nil) ::
          :inet.ip_address() | nil
  def resolve(x_headers, peer_address) do
    case from_platform_header(x_headers) do
      nil -> resolve_proxies(x_headers, peer_address)
      client -> client
    end
  end

  defp resolve_proxies(x_headers, peer_address) do
    case proxies() do
      [] ->
        warn_once_if_forwarded(x_headers)
        peer_address

      list ->
        from_headers(x_headers, list) || peer_address
    end
  end

  # `RemoteIp.from/2` inits the options itself, so the cached `remote_ip_opts/1`
  # cannot be handed to it. It is still consulted first, because `RemoteIp.init/1`
  # RAISES on a malformed CIDR and that cache is where the outcome is remembered:
  # without it a bad list would construct an exception and a stacktrace on every
  # socket connect, forever, with the log latched silent after the first. A bad
  # list degrades to "trust nothing", for the same reason it does in `call/2` —
  # a spoofable header is never honoured on the way down.
  defp from_headers(x_headers, list) do
    case remote_ip_opts(list) do
      {:ok, _cached} -> RemoteIp.from(x_headers, proxies: list)
      :error -> nil
    end
  end

  @doc false
  # Exposed so tests can start from a known latch state — otherwise the first
  # forwarded request in a run silences every later one.
  def reset_forwarding_warning do
    :persistent_term.erase(@warned_key)
    :ok
  end

  # The latch is checked before the headers so that, once warned, the steady
  # state is a single `persistent_term` read rather than a header scan.
  #
  # Takes the header list rather than a conn so the socket path shares it: a
  # deployment whose only traffic is WebSocket upgrades collapses its buckets
  # exactly the same way, and a detection that only ran for `Plug.Conn` would
  # stay silent for it — which is the shape of trap this exists to catch.
  defp warn_once_if_forwarded(headers) do
    if :persistent_term.get(@warned_key, false) do
      :ok
    else
      if forwarded?(headers), do: warn_untrusted_forwarding(), else: :ok
    end
  end

  defp forwarded?(headers),
    do: Enum.any?(headers, fn {name, _value} -> name in @forwarding_headers end)

  defp warn_untrusted_forwarding do
    :persistent_term.put(@warned_key, true)

    # The header value is deliberately NOT logged: it is attacker-controlled,
    # and its contents add nothing — that it arrived at all is the whole signal.
    Logger.warning("""
    A request arrived carrying a forwarding header (one of \
    #{Enum.join(@forwarding_headers, ", ")}) but TRUSTED_PROXIES is unset, so it \
    was ignored and rate limiting is keying on whatever address connected — the \
    proxy's, if there is one in front. Every rate-limit bucket is then shared by \
    all traffic, and the per-IP brute-force protection on /sign-in and \
    /api/auth/sign_in is not per-IP. If this app sits behind a reverse proxy, set \
    TRUSTED_PROXIES to that proxy's CIDRs, e.g. \
    TRUSTED_PROXIES=10.0.0.0/8,172.16.0.0/12. On Fly.io, Railway or \
    DigitalOcean App Platform, set CLIENT_IP_HEADER instead (see \
    docs/deploy-platforms.md). If it is internet-facing and a \
    client simply sent the header, ignoring it is correct and this warning needs \
    no action. Logged once per node.\
    """)

    :ok
  end

  defp proxies, do: Application.get_env(:kiln_cms, :trusted_proxies, [])

  @doc """
  What `CLIENT_IP_HEADER` resolves to, given the process environment (#1548).
  Called by `config/runtime/prod/web.exs`; the result is
  `config :kiln_cms, :client_ip_header`.

    * `nil` — unset or blank. The header path is off.
    * `{:header, name}` — honour `name`: it is a platform header, and every
      marker variable that platform sets is present.
    * `{:refused, name, reason}` — set, but not honoured. The plug logs
      `reason` once, on the first request, and behaves as if it were unset.

  Refusing rather than raising is deliberate: the safe fallback (the peer, or
  `TRUSTED_PROXIES`) is a working deployment with coarser rate limits, and a
  boot failure over a rate-limit setting would take the site down instead.
  """
  @spec header_setting(%{optional(String.t()) => String.t()}) ::
          nil | {:header, String.t()} | {:refused, String.t(), String.t()}
  def header_setting(env) do
    case env |> Map.get("CLIENT_IP_HEADER", "") |> String.trim() |> String.downcase() do
      "" -> nil
      name -> header_setting(name, Map.fetch(@platform_headers, name), env)
    end
  end

  defp header_setting(name, :error, _env) do
    supported = @platform_headers |> Map.keys() |> Enum.sort() |> Enum.join(", ")

    {:refused, name,
     "CLIENT_IP_HEADER=#{name} is not a header Kiln knows a platform proxy to set. " <>
       "Supported: #{supported}. Behind any other proxy, use TRUSTED_PROXIES."}
  end

  defp header_setting(name, {:ok, {platform, markers}}, env) do
    case Enum.reject(markers, &marker_present?(&1, env)) do
      [] ->
        {:header, name}

      missing ->
        {:refused, name,
         "CLIENT_IP_HEADER=#{name} is #{platform}'s client-address header, but " <>
           "#{Enum.join(missing, " and ")} #{if match?([_], missing), do: "is", else: "are"} " <>
           "not set, so this does not look like " <>
           "#{platform}. Anywhere else a client can send that header itself and " <>
           "choose its own rate-limit bucket, so it is being ignored."}
    end
  end

  defp marker_present?("APP_ID" = var, env) do
    case Ecto.UUID.cast(Map.get(env, var, "")) do
      {:ok, _} -> true
      :error -> false
    end
  end

  defp marker_present?(var, env), do: String.trim(Map.get(env, var, "")) != ""

  # The client address from the platform's own header, or nil to fall through
  # to the `TRUSTED_PROXIES` path. A request without the header — a health
  # probe, or one over the platform's private network that bypassed its proxy
  # — falls through too, as does a value that is not exactly one address: the
  # proxy writes a single address, so anything else did not come from it.
  defp from_platform_header(headers) do
    case Application.get_env(:kiln_cms, :client_ip_header) do
      {:header, name} ->
        with {_, value} <- List.keyfind(headers, name, 0),
             {:ok, address} <- :inet.parse_strict_address(String.to_charlist(String.trim(value))) do
          address
        else
          _ -> nil
        end

      {:refused, _name, reason} ->
        log_refused_header_once(reason)
        nil

      _ ->
        nil
    end
  end

  defp log_refused_header_once(reason) do
    if :persistent_term.get(@refused_header_key, false) do
      :ok
    else
      :persistent_term.put(@refused_header_key, true)
      Logger.error(reason <> " Logged once per node.")
    end
  end

  @doc false
  # Tests start from a known latch state, as with `reset_forwarding_warning/0`.
  def reset_refused_header_warning do
    :persistent_term.erase(@refused_header_key)
    :ok
  end

  # Keyed on the proxy list, not on a bare `:opts`, so changing the list at
  # runtime rebuilds rather than serving the CIDRs the node booted with.
  #
  # `RemoteIp.init/1` RAISES on a malformed CIDR, and this plug sits in the
  # endpoint ahead of the router — so an unrescued raise would 500 every request
  # including `/up`, marking the container unhealthy, and would repeat forever
  # because the cache is only written on success. A bad list therefore degrades
  # to "trust nothing", which is the same posture as leaving the variable unset
  # and the safe direction to fail in: a spoofable header is never honoured.
  defp remote_ip_opts(list) do
    key = {__MODULE__, :opts, list}

    case :persistent_term.get(key, nil) do
      nil ->
        opts = {:ok, RemoteIp.init(proxies: list)}
        :persistent_term.put(key, opts)
        opts

      opts ->
        opts
    end
  rescue
    error ->
      log_bad_proxies_once(list, error)
      :error
  end

  defp log_bad_proxies_once(list, error) do
    if :persistent_term.get(@bad_proxies_key, false) do
      :ok
    else
      :persistent_term.put(@bad_proxies_key, true)

      Logger.error("""
      TRUSTED_PROXIES could not be parsed (#{Exception.message(error)}), so no \
      proxy is being trusted and rate limiting is keying on whatever address \
      connects — as if the variable were unset. Entries must be CIDRs or plain \
      IPs, e.g. TRUSTED_PROXIES=10.0.0.0/8,172.16.0.0/12. Got: \
      #{inspect(list)}. Logged once per node.\
      """)
    end
  end
end
