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
      `:auth` and `:form` are 20/min *in total*, across all users;
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

  @impl true
  def init(_opts), do: []

  @impl true
  def call(conn, _opts) do
    case proxies() do
      [] ->
        warn_once_if_forwarded(conn)
        conn

      list ->
        case remote_ip_opts(list) do
          {:ok, opts} -> RemoteIp.call(conn, opts)
          :error -> conn
        end
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
  defp warn_once_if_forwarded(conn) do
    if :persistent_term.get(@warned_key, false) do
      :ok
    else
      if forwarded?(conn), do: warn_untrusted_forwarding(), else: :ok
    end
  end

  defp forwarded?(conn),
    do: Enum.any?(conn.req_headers, fn {name, _value} -> name in @forwarding_headers end)

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
    TRUSTED_PROXIES=10.0.0.0/8,172.16.0.0/12. If it is internet-facing and a \
    client simply sent the header, ignoring it is correct and this warning needs \
    no action. Logged once per node.\
    """)

    :ok
  end

  defp proxies, do: Application.get_env(:kiln_cms, :trusted_proxies, [])

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
