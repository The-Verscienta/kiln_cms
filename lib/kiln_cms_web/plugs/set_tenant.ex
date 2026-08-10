defmodule KilnCMSWeb.Plugs.SetTenant do
  @moduledoc """
  Resolves the request's organization from its host and sets it as the Ash tenant
  (epic #336).

  Runs in the endpoint (after `SetLocale`, before the router) so it precedes every
  pipeline. Calling `Ash.PlugHelpers.set_tenant/2` makes the headless
  GraphQL/JSON:API surfaces (`AshGraphql.Plug`, `AshJsonApi`) tenant-scoped with no
  resolver changes, and `assign(:current_org, org)` gives the controllers /
  LiveViews the org for their reads (see `KilnCMSWeb.Tenant`).

  Resolution (subdomain → custom domain → default org) is `KilnCMSWeb.Tenant.fetch_org/1`,
  shared with the LiveView `:assign_current_org` on_mount hook. It normally always
  yields an org, so a bare-host / `localhost` request transparently serves the
  default org — the non-breaking single-host behavior.

  Under `TENANT_STRICT_HOST=true` (#563) that last fallback is gone and an
  unresolvable host gets a bare `404` here, in the endpoint: no tenant assigned,
  the router never reached, the pipeline halted.

  It answers directly rather than raising a `plug_status: 404` exception for the
  error renderer, for two reasons. The 404 template renders `Layouts.public`,
  which brands itself from the default org when it has none — so the "unknown
  hosts get nothing of the default site" guarantee would leak the default site's
  name and logo through its own rejection page. And a scan across ten thousand
  made-up `Host` headers should not each render a HEEx page.
  `KilnCMSWeb.Tenant.UnknownHostError` still exists for the LiveView mount path,
  where raising is the only way to refuse.

  ## The refusal no longer costs a query every time (#659)

  A refused request is halted here, above the router — and every rate limiter
  lives in a router *pipeline*, so turning strict matching on took this path out
  of `:delivery`'s ceiling and left one uncached organization lookup per request,
  metered by nothing.

  Unresolvable hosts are now **cached as misses**, in `KilnCMS.Cache.Hosts` —
  a cache of their own, precisely so they can be: in the shared content cache a
  flood of invented hosts would have evicted hot published pages, which is why
  `nil` was never committed there. A repeated flood now costs one lookup per
  distinct host per minute instead of one per request.

  A flood of *distinct* hosts still costs a lookup each, and deliberately so.
  Bounding that needs a per-IP budget that refuses without resolving — which
  cannot tell a flood from a legitimate request behind the same NAT, CDN or
  collapsed `X-Forwarded-For`, and so would refuse hosts that do exist. Trading
  a bounded amount of indexed-lookup load for the ability to 404 real tenants is
  the wrong trade; terminate unknown hosts at the proxy if the load matters.

  What was missing until #678 was not a bound on that cost but any way for an
  operator to *see* it happening: see `KilnCMSWeb.TenantRefusalAlert`, called
  from the branch below that actually refuses (never from the exemption branch
  above it, and never from `Tenant.fetch_org/1` itself, which health probes and
  the billing webhook also call on their way to being served).

  ## What the refusal still reveals

  An unknown host gets this plain-text 404; a **known** host with an unmatched
  path gets the branded HTML 404 from `KilnCMSWeb.ErrorHTML`. The two are
  distinguishable, so a dictionary sweep of `<candidate>.<base host>` enumerates
  which org slugs exist — and against apex names, which `custom_domain`s are
  configured. The status code is identical; the body is not.

  This is **accepted, not fixed** (#659). Making the two identical means either
  serving the branded page to unknown hosts — which reintroduces exactly the
  default-org leak this control exists to prevent — or serving the plain page to
  everybody, which degrades a real 404 for every tenant to close an oracle over
  names that are already public in DNS and in TLS certificates. A deployment
  whose tenant list is genuinely confidential should terminate unknown hosts at
  the proxy, where one uniform response covers both cases; the deploy recipes in
  `docs/` already assume that arrangement.

  Two controllers are exempt from the rejection because they are deliberately
  host-independent — see `@host_agnostic_controllers`. Neither reads the ambient
  tenant, so exempting them leaks nothing, and both resolve leniently exactly as
  before.
  """
  @behaviour Plug

  import Plug.Conn

  require Logger

  # Controllers that must keep answering on a `Host` that resolves to no org:
  #
  #   * `HealthController` — a load balancer, uptime monitor or orchestrator
  #     sends whatever `Host` it likes, typically the container's IP. Refusing
  #     it would take a correctly configured deployment and mark it unhealthy,
  #     which is the one failure mode a safety control must not have.
  #   * `BillingWebhookController` — a provider webhook arrives at whatever host
  #     the endpoint was registered with, is authorized by an HMAC over the raw
  #     body rather than by the ambient tenant, and resolves its organization
  #     from the event payload (its moduledoc says so in as many words).
  #     Refusing it diverges membership state silently and eventually gets the
  #     endpoint disabled by the provider.
  #
  # Keyed on the controller, asked of the compiled router, rather than on a
  # hand-copied path list — so a route added to either one is covered the day it
  # lands and nothing here drifts out of sync with `KilnCMSWeb.Router`.
  @host_agnostic_controllers [
    KilnCMSWeb.HealthController,
    KilnCMSWeb.BillingWebhookController
  ]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case KilnCMSWeb.Tenant.fetch_org(conn.host) do
      {:ok, org} -> put_tenant(conn, org)
      :error -> reject(conn)
    end
  end

  defp reject(conn) do
    if host_agnostic?(conn) do
      put_tenant(conn, KilnCMSWeb.Tenant.resolve_org(conn.host))
    else
      # Debug, not warning: on the public internet an unmatched Host is constant
      # background scanning, and one log line per rejection is the same
      # unbounded write the plain response is avoiding. An operator debugging a
      # tenant that won't resolve drops the level and sees exactly which host
      # missed.
      Logger.debug(fn -> "SetTenant: rejected unknown host #{inspect(conn.host)}" end)
      KilnCMSWeb.TenantRefusalAlert.notify(:plug, conn.host)

      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "Not Found: this server does not serve the requested host.\n")
      |> halt()
    end
  end

  # The plug runs ahead of the router, but the router module is compiled and can
  # be asked which controller a path would reach. Only reached once a host has
  # already failed to resolve under strict matching, so it costs nothing on the
  # normal path.
  #
  # `route_info/4` splits and normalizes the path the same way the router does,
  # so `/up/` and `//up` land on the same route the router would pick — which a
  # raw `request_path` string comparison would miss. `conn.method` is already
  # normalized too: `Plug.Head` rewrites HEAD to GET earlier in the endpoint.
  defp host_agnostic?(conn) do
    case Phoenix.Router.route_info(KilnCMSWeb.Router, conn.method, conn.request_path, conn.host) do
      %{plug: plug} -> plug in @host_agnostic_controllers
      _no_route -> false
    end
  end

  defp put_tenant(conn, org) do
    conn
    |> Ash.PlugHelpers.set_tenant(org)
    |> assign(:current_org, org)
  end
end
