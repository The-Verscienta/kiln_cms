defmodule KilnCMSWeb.Tenant do
  @moduledoc """
  Web-layer tenant resolution (epic #336).

  A request's organization is derived from its **host**:

    1. a subdomain of the configured base host (`acme.example.com` → org `acme`),
    2. else an exact custom domain (`www.acme.com`),
    3. else the **default org** (bare base host / `localhost` / IP / unknown) — so
       an existing single-host install keeps serving the default org unchanged.

  `fetch_org/1` is the single resolver, shared by `KilnCMSWeb.Plugs.SetTenant`
  (from `conn.host`) and the LiveView `:assign_current_org` on_mount hook (from the
  socket's `host_uri`). Lookups are Cachex-cached so resolution isn't a DB hit per
  request. `current_org_id/1` reads the resolved org back off a conn/socket's
  `:current_org` assign.

  ## Strict host mode (#563)

  Step 3 is right for a single-org install and wrong for a multi-org one: any
  request arriving with an unrecognised `Host` — a bare hostname, an IP literal,
  `localhost`, or an attacker-supplied header — is served the default org's
  content, branding and analytics rather than being refused.

  `TENANT_STRICT_HOST=true` (config `:tenant_strict_host`) drops step 3, so an
  unresolvable host is a 404 instead. Off by default, because turning it on for
  a single-host deployment whose `PHX_HOST` is misconfigured would take the site
  down; recommended for anything serving more than one organization. Probe paths
  (`:tenant_strict_host_exempt_paths`, default `/up`) stay exempt either way —
  load balancers health-check by pod IP, and a 404 there reads as an unhealthy
  instance and pulls it out of rotation.

  Unknown hosts are deliberately **not** cached in either mode, so a flood of
  distinct `Host` headers cannot evict hot entries from the shared content cache.
  """
  alias KilnCMS.Accounts

  require Logger

  # How long a host→org resolution is cached. Short enough that a slug/custom-domain
  # change (rare, admin-only) is picked up promptly.
  @cache_ttl :timer.minutes(5)

  @doc """
  The current organization id from a conn/socket assign.

  Raises when the assign is absent — see `current_org/1`.
  """
  @spec current_org_id(map()) :: Ash.UUID.t()
  def current_org_id(assigns), do: current_org(assigns).id

  @doc """
  The current org struct from a conn/socket assign.

  `KilnCMSWeb.Plugs.SetTenant` sets `:current_org` in the endpoint for every HTTP
  request, and the `:assign_current_org` on_mount does the same for every
  LiveView, so every real request has it by the time a caller asks.

  Reaching here without it therefore means a caller bypassed both — and this
  used to quietly return the **default org**, which on a multi-org deployment is
  a cross-tenant read that looks like a working page (#563). It now raises, so
  the missed assign surfaces as a failing test rather than as another org's
  content in production.

  Where the fallback is genuinely wanted, say so with `current_org_or_default/1`.
  """
  @spec current_org(map()) :: Accounts.Organization.t()
  def current_org(%{assigns: %{current_org: %Accounts.Organization{} = org}}), do: org

  def current_org(other) do
    raise ArgumentError, """
    KilnCMSWeb.Tenant.current_org/1 called without a :current_org assign.

    Got: #{describe(other)}

    Every HTTP request gets this assign from KilnCMSWeb.Plugs.SetTenant (in the
    endpoint, before the router) and every LiveView from the :assign_current_org
    on_mount hook. If you are here, the caller reached this code some other way —
    a bare map, a socket mounted outside a live_session, or a test conn built
    without the plug pipeline.

    Returning the default org instead would be a cross-tenant read on a
    multi-org deployment, so this raises (#563). If the default really is the
    right answer for this call site, use current_org_or_default/1 and say why.
    """
  end

  @doc """
  The current org from a conn/socket assign, **or the default org** when the
  assign is absent.

  The explicit form of what `current_org/1` used to do implicitly. Reach for it
  only where a missing assign is expected and the default org is the right
  answer — rendering a shared layout for a request that never had a tenant, for
  instance. Anywhere else, prefer `current_org/1` and let it raise.

  Never `nil`: `Accounts.default_org/0` reads a seed row that can be missing on a
  broken or uninitialised install, so a synthetic id-only struct is the final
  fallback rather than a `nil` for callers to crash on.
  """
  @spec current_org_or_default(map()) :: Accounts.Organization.t()
  def current_org_or_default(%{assigns: %{current_org: %Accounts.Organization{} = org}}), do: org

  def current_org_or_default(_), do: default_org()

  @doc "The id form of `current_org_or_default/1`."
  @spec current_org_id_or_default(map()) :: Ash.UUID.t()
  def current_org_id_or_default(assigns), do: current_org_or_default(assigns).id

  @doc """
  The default org, and never `nil`.

  `Accounts.default_org/0` reads a seed row, which can miss on a broken or
  uninitialised install — and returns `nil` rather than raising when the database
  is unreachable, which delivery deliberately survives (#341). A synthetic
  id-only struct is the final fallback, so no caller is handed a `nil` to crash
  on.
  """
  @spec default_org() :: Accounts.Organization.t()
  def default_org,
    do: Accounts.default_org() || %Accounts.Organization{id: Accounts.default_org_id()}

  # Conns and sockets carry request bodies, session data and assigns that may
  # hold user records — none of which belongs in an exception message that ends
  # up in logs or Sentry. Report the shape, not the contents. Returns a string
  # ready to interpolate, so callers must NOT `inspect/1` the result again.
  #
  # A `%Phoenix.LiveView.Socket{}` deliberately has no clause of its own: it
  # matches the `assigns` clause, which names the assigns it *does* have — the
  # only useful thing to know about a LiveView that mounted outside a
  # `live_session` carrying `:assign_current_org`.
  defp describe(%Plug.Conn{} = conn), do: "%Plug.Conn{host: #{inspect(conn.host)}}"

  defp describe(%{assigns: assigns}) when is_map(assigns),
    do: "a conn/socket whose assigns are #{inspect(Map.keys(assigns))}"

  defp describe(other) when is_map(other),
    do: "a map with keys #{inspect(Map.keys(other))}"

  defp describe(other), do: inspect(other)

  @doc """
  The given org's own absolute base URL (scheme + host [+ port]), for building
  public-facing URLs (canonical tags, JSON-LD, sitemap, `llms.txt`, static
  export). A `custom_domain` always wins (even on the default org — an
  operator can vanity-domain the pre-existing single-tenant site without
  touching `:public_base_url`); otherwise the default org keeps the
  deployment-global `:public_base_url` and every other org gets that same
  scheme/port with `<slug>.<base_host>` substituted in.

  Accepts an `%Organization{}`, a bare org id, or `nil` (→ the global default).
  """
  @spec base_url(Accounts.Organization.t() | Ash.UUID.t() | nil) :: String.t()
  def base_url(%Accounts.Organization{} = org) do
    cond do
      is_binary(org.custom_domain) -> with_host(global_base_url(), org.custom_domain)
      org.id == Accounts.default_org_id() -> global_base_url()
      true -> with_host(global_base_url(), "#{org.slug}.#{base_host()}")
    end
  end

  def base_url(nil), do: global_base_url()

  def base_url(org_id) when is_binary(org_id) do
    if org_id == Accounts.default_org_id() do
      global_base_url()
    else
      case Accounts.get_organization(org_id, authorize?: false) do
        {:ok, org} ->
          base_url(org)

        _ ->
          Logger.warning("KilnCMSWeb.Tenant.base_url/1: unknown org id #{org_id}")
          global_base_url()
      end
    end
  end

  defp global_base_url,
    do: Application.get_env(:kiln_cms, :public_base_url, "http://localhost:4000")

  defp with_host(base_url, host),
    do: base_url |> URI.parse() |> Map.put(:host, host) |> URI.to_string()

  @doc """
  Resolve the organization for a request host.

  `{:ok, org}` when the host maps to one, or when it does not and strict host
  mode is off (the default org — the single-host behaviour). `:error` only when
  the host maps to no org **and** `:tenant_strict_host` is on; callers should
  refuse the request rather than substitute a tenant (#563).
  """
  @spec fetch_org(String.t() | nil) :: {:ok, Accounts.Organization.t()} | :error
  def fetch_org(host) do
    case known_org(host) do
      %Accounts.Organization{} = org -> {:ok, org}
      nil -> if strict_host?(), do: :error, else: {:ok, default_org()}
    end
  end

  @doc """
  Resolve the organization for a request host, falling back to the default org
  for an unknown one **even in strict mode**.

  For callers that have no way to refuse — a background job or a mailer building
  URLs off a stored host. Request paths should use `fetch_org/1`.
  """
  @spec resolve_org(String.t() | nil) :: Accounts.Organization.t()
  def resolve_org(host), do: known_org(host) || default_org()

  # The org a host actually names, or `nil` when it names none.
  defp known_org(host) when is_binary(host) and host != "" do
    # Hostnames are case-insensitive (RFC 3986) and `socket.host_uri`/`conn.host`
    # aren't normalized, so downcase before matching/caching — otherwise
    # `Acme.Example.com` fails the suffix/slug match and mis-resolves to the
    # default org, and case variants fragment the cache (#336 review).
    #
    # The trailing dot of a rooted FQDN is stripped for the same reason: browsers
    # send `Host: acme.example.com.` verbatim when the user types the fully
    # qualified form, and it is DNS-identical to the undotted one. Left in, it
    # matches no suffix and no custom domain — which under lenient mode quietly
    # resolves `victim.example.com.` to the DEFAULT org, and under strict mode
    # 404s a hostname that works without the dot (#563).
    #
    # Only KNOWN hosts (the base host + real org subdomains/custom domains) are
    # cached; an unknown/unresolved host returns `nil` here, uncached. This keeps
    # a flood of distinct attacker Host headers under `*.<base>` from inserting
    # per-host entries into the shared, size-capped content cache and evicting
    # hot published pages (#336 review, resolution-cache DoS).
    host
    |> String.downcase()
    |> String.trim_trailing(".")
    |> resolve_cached()
  end

  defp known_org(_), do: nil

  @doc """
  Whether an unresolvable `Host` is refused rather than served the default org.

  `TENANT_STRICT_HOST`, off by default — see the module doc.
  """
  @spec strict_host?() :: boolean()
  def strict_host?, do: Application.get_env(:kiln_cms, :tenant_strict_host, false)

  @doc """
  Request paths exempt from strict host mode, as a list of exact paths.

  Defaults to both health probes (`KilnCMSWeb.HealthController`): load balancers
  and uptime monitors check by pod IP or an internal DNS name that resolves to no
  org, and 404ing that reads as an unhealthy instance and pulls it out of
  rotation — the fix would take the deployment down.

  Override with `:tenant_strict_host_exempt_paths` for anything else that is
  addressed by something other than a site hostname; an ACME `http-01` challenge
  is the usual case, if this deployment answers those itself rather than behind a
  proxy that terminates TLS.

  Exempt paths are matched exactly, on `conn.request_path`, and serve the default
  org — so nothing org-specific belongs on this list.
  """
  @spec strict_host_exempt_paths() :: [String.t()]
  def strict_host_exempt_paths,
    do: Application.get_env(:kiln_cms, :tenant_strict_host_exempt_paths, ["/up", "/ready"])

  defp resolve_cached(host) do
    KilnCMS.Cache.fetch({:tenant_host, host}, @cache_ttl, fn -> resolve_known(host) end)
  end

  # A real org (by subdomain slug or custom domain), or the default org when the
  # host IS the canonical base host. `nil` for anything else — a `nil` is not
  # cached (see `KilnCMS.Cache.commit/2`), so unknown hosts never pollute the cache.
  defp resolve_known(host) do
    cond do
      host == base_host() -> Accounts.default_org()
      org = by_subdomain(host) -> org
      org = by_custom_domain(host) -> org
      true -> nil
    end
  end

  # A subdomain of the base host resolves by org slug. The bare base host (no
  # subdomain) and any host not under the base fall through to custom-domain /
  # default resolution.
  defp by_subdomain(host) do
    base = base_host()
    suffix = "." <> base

    if host != base and String.ends_with?(host, suffix) do
      slug = String.replace_suffix(host, suffix, "")
      # A multi-label prefix (`a.b.example.com`) isn't a tenant slug.
      if slug != "" and not String.contains?(slug, "."), do: lookup(:slug, slug)
    end
  end

  defp by_custom_domain(host), do: lookup(:custom_domain, host)

  defp lookup(:slug, value) do
    case Accounts.get_organization_by_slug(value, authorize?: false) do
      {:ok, org} -> org
      _ -> nil
    end
  end

  defp lookup(:custom_domain, value) do
    case Accounts.get_organization_by_domain(value, authorize?: false) do
      {:ok, org} -> org
      _ -> nil
    end
  end

  @doc """
  The base host subdomains are carved from. Defaults to the endpoint's canonical
  `url[:host]` (i.e. `PHX_HOST`); override with `config :kiln_cms, :tenant_base_host`.
  """
  @spec base_host() :: String.t()
  def base_host do
    # Downcased to match `known_org/1`, which downcases the request host. Without
    # this a `PHX_HOST=Acme.Com` fails both `host == base_host()` and the
    # `.Acme.Com` suffix test, so NO host resolves — invisible while an unknown
    # host falls back to the default org, and a total outage the moment strict
    # host mode is turned on (#563).
    (Application.get_env(:kiln_cms, :tenant_base_host) ||
       get_in(Application.get_env(:kiln_cms, KilnCMSWeb.Endpoint, []), [:url, :host]) ||
       "localhost")
    |> String.downcase()
  end
end
