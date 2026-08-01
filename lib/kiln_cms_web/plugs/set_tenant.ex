defmodule KilnCMSWeb.Plugs.SetTenant do
  @moduledoc """
  Resolves the request's organization from its host and sets it as the Ash tenant
  (epic #336).

  Runs in the endpoint (after `SetLocale`, before the router) so it precedes every
  pipeline. Calling `Ash.PlugHelpers.set_tenant/2` makes the headless
  GraphQL/JSON:API surfaces (`AshGraphql.Plug`, `AshJsonApi`) tenant-scoped with no
  resolver changes, and `assign(:current_org, org)` gives the controllers /
  LiveViews the org for their reads (see `KilnCMSWeb.Tenant`).

  Resolution (subdomain → custom domain → default org) is
  `KilnCMSWeb.Tenant.fetch_org/1`, shared with the LiveView `:assign_current_org`
  on_mount hook.

  ## Unknown hosts (#563)

  By default an unresolvable host still yields the default org, so a bare-host /
  `localhost` request transparently serves it — the non-breaking single-host
  behaviour. Under `TENANT_STRICT_HOST=true` it is refused with a **404**
  instead, because on a multi-org deployment serving the default org to an
  unrecognised `Host` hands one tenant's content out under another's name.

  404 rather than 400: an unknown host is indistinguishable from a host that
  simply has no site here, and a 404 says so without confirming which hostnames
  do exist. The body is deliberately bare text — rendering the normal error page
  would need a tenant, which is the thing that just failed to resolve.

  Paths in `Tenant.strict_host_exempt_paths/0` (default `/up`) skip the check, so
  a load balancer health-checking by pod IP does not take the instance out of
  rotation. This plug runs before the router and so cannot ask which route
  matched; the exemption is therefore by exact request path.
  """
  @behaviour Plug

  import Plug.Conn

  require Logger

  @log_key {__MODULE__, :last_refusal_log_ms}
  @log_every_ms :timer.minutes(1)

  @doc """
  Clears the refusal-log throttle. For tests, which would otherwise be
  order-dependent: the first refusal anywhere in a run suppresses the line for
  everyone after it.
  """
  @spec reset_log_throttle() :: :ok
  def reset_log_throttle do
    :persistent_term.erase(@log_key)
    :ok
  end

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case KilnCMSWeb.Tenant.fetch_org(conn.host) do
      {:ok, org} ->
        put_org(conn, org)

      # Reaching `:error` already proves the host matches no org, so the exempt
      # branch goes straight to the default org — calling `resolve_org/1` here
      # would repeat the (uncached, unknown hosts are never cached) lookup on the
      # one path a load balancer hits every second, forever.
      :error ->
        if exempt?(conn) do
          put_org(conn, KilnCMSWeb.Tenant.default_org())
        else
          refuse(conn)
        end
    end
  end

  defp put_org(conn, org) do
    conn
    |> Ash.PlugHelpers.set_tenant(org)
    |> assign(:current_org, org)
  end

  defp exempt?(conn), do: conn.request_path in KilnCMSWeb.Tenant.strict_host_exempt_paths()

  defp refuse(conn) do
    log_refusal(conn.host)

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "No site is configured for this host.\n")
    |> halt()
  end

  # Throttled to at most one line per `@log_every_ms` per node.
  #
  # The refusal halts inside the endpoint, ahead of the router — so ahead of
  # `Plugs.RateLimit`, which is a router pipeline plug. An unthrottled line here
  # would hand anyone cycling `Host:` values a log-volume amplifier on a path
  # nothing else meters, and drown the real warnings in the process. The point of
  # the warning is that an operator who has just turned the flag on finds out
  # they refused something; one line a minute carries that.
  #
  # The host is attacker-controlled, so it goes through `inspect/1` rather than
  # being interpolated raw — a value carrying newlines must not forge log lines.
  defp log_refusal(host) do
    now = System.monotonic_time(:millisecond)
    last = :persistent_term.get(@log_key, nil)

    if is_nil(last) or now - last >= @log_every_ms do
      :persistent_term.put(@log_key, now)

      Logger.warning(
        "Refused request for unknown host #{inspect(host)} (TENANT_STRICT_HOST is on). " <>
          "Further refusals are logged at most once every #{div(@log_every_ms, 1000)}s."
      )
    end

    :ok
  end
end
