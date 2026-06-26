defmodule KilnCMSWeb.Plugs.ClientIp do
  @moduledoc """
  Rewrites `conn.remote_ip` to the real client IP parsed from `X-Forwarded-For`
  when the request arrives through a **trusted** reverse proxy, so IP-based rate
  limiting (`KilnCMSWeb.Plugs.RateLimit`) keys on the client rather than the
  proxy address.

  Trusted proxy CIDRs come from `config :kiln_cms, :trusted_proxies` (set via the
  `TRUSTED_PROXIES` env var in `config/runtime.exs`). When none are configured
  this is a no-op and `remote_ip` stays the direct peer — the correct behaviour
  for an internet-facing deployment where `X-Forwarded-For` is attacker-spoofable.

  The plug wraps `RemoteIp` rather than using it directly because the endpoint
  builds plug `init/1` at compile time, while the proxy list is only known at
  runtime; options are therefore built lazily on first use and cached.
  """
  @behaviour Plug

  @impl true
  def init(_opts), do: []

  @impl true
  def call(conn, _opts) do
    case proxies() do
      [] -> conn
      _ -> RemoteIp.call(conn, remote_ip_opts())
    end
  end

  defp proxies, do: Application.get_env(:kiln_cms, :trusted_proxies, [])

  defp remote_ip_opts do
    case :persistent_term.get({__MODULE__, :opts}, nil) do
      nil ->
        opts = RemoteIp.init(proxies: proxies())
        :persistent_term.put({__MODULE__, :opts}, opts)
        opts

      opts ->
        opts
    end
  end
end
