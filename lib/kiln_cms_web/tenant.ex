defmodule KilnCMSWeb.Tenant do
  @moduledoc """
  Web-layer tenant resolution (epic #336).

  A request's organization is derived from its **host**:

    1. a subdomain of the configured base host (`acme.example.com` → org `acme`),
    2. else an exact custom domain (`www.acme.com`),
    3. else the **default org** (bare base host / `localhost` / IP / unknown) — so
       an existing single-host install keeps serving the default org unchanged.

  `resolve_org/1` is the single resolver, shared by `KilnCMSWeb.Plugs.SetTenant`
  (from `conn.host`) and the LiveView `:assign_current_org` on_mount hook (from the
  socket's `host_uri`). Lookups are Cachex-cached so resolution isn't a DB hit per
  request. `current_org_id/1` reads the resolved org back off a conn/socket's
  `:current_org` assign.
  """
  alias KilnCMS.Accounts

  # How long a host→org resolution is cached. Short enough that a slug/custom-domain
  # change (rare, admin-only) is picked up promptly.
  @cache_ttl :timer.minutes(5)

  @doc "The current organization id from a conn/socket assign, or the default org id."
  @spec current_org_id(map()) :: Ash.UUID.t()
  def current_org_id(%{assigns: %{current_org: %{id: id}}}), do: id
  def current_org_id(_), do: Accounts.default_org_id()

  @doc """
  Resolve the organization for a request host. Always returns an org struct
  (falls back to the default org), so callers never have to handle `nil`.
  """
  @spec resolve_org(String.t() | nil) :: KilnCMS.Accounts.Organization.t()
  def resolve_org(host) when is_binary(host) and host != "" do
    # Hostnames are case-insensitive (RFC 3986) and `socket.host_uri`/`conn.host`
    # aren't normalized, so downcase before matching/caching — otherwise
    # `Acme.Example.com` fails the suffix/slug match and mis-resolves to the
    # default org, and case variants fragment the cache (#336 review).
    host = String.downcase(host)

    # Only KNOWN hosts (the base host + real org subdomains/custom domains) are
    # cached; an unknown/unresolved host returns `nil` here (uncached) and the
    # caller supplies the default org. This keeps a flood of distinct attacker
    # Host headers under `*.<base>` from inserting per-host entries into the
    # shared, size-capped content cache and evicting hot published pages (#336
    # review, resolution-cache DoS).
    resolve_cached(host) || Accounts.default_org()
  end

  def resolve_org(_), do: Accounts.default_org()

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
    Application.get_env(:kiln_cms, :tenant_base_host) ||
      get_in(Application.get_env(:kiln_cms, KilnCMSWeb.Endpoint, []), [:url, :host]) ||
      "localhost"
  end
end
