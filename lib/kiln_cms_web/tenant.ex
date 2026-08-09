defmodule KilnCMSWeb.Tenant do
  @moduledoc """
  Web-layer tenant resolution (epic #336).

  A request's organization is derived from its **host**:

    1. a subdomain of the configured base host (`acme.example.com` → org `acme`),
    2. else an exact custom domain (`www.acme.com`),
    3. else the **default org** (bare base host / `localhost` / IP / unknown) — so
       an existing single-host install keeps serving the default org unchanged.

  Step 3 is the single-host convenience, and on a multi-tenant deployment it is
  the wrong answer: any request carrying an unrecognised `Host` gets the default
  org's content, branding and analytics. `TENANT_STRICT_HOST=true` (#563) drops
  that fallback — an unresolvable host is refused instead. It is off by default
  so an existing single-host install is unaffected, and recommended for every
  multi-tenant one.

  `fetch_org/1` is the single resolver — `{:ok, org}` or `:error` under strict
  matching — shared by `KilnCMSWeb.Plugs.SetTenant` (from `conn.host`), the
  LiveView `:assign_current_org` on_mount hook (from the socket's `host_uri`)
  and all three sockets (`GraphqlSocket`, `BridgeSocket`, `CollabSocket`, from
  the connect URI via `fetch_org_from_connect_info/1`). `resolve_org/1` is the
  never-failing form, for callers with no way to reject a request. Lookups are
  Cachex-cached so resolution isn't a DB hit per request.

  ## What strict matching does not cover

  It gates what the **router** serves, plus the sockets listed above. One thing
  sits outside it by design, and it carries no org-scoped reads:

    * `Plug.Static` — both static mounts (including `/uploads` under the local
      storage adapter) run earlier in the endpoint and halt on a match, so an
      asset URL answers on any host. Asset keys are unguessable UUIDs, and
      putting tenant resolution ahead of static would buy two DB lookups per
      asset request; treat media URLs as host-agnostic, as they would be behind
      a CDN.

  `/ws/collab` was a second until #655: it resolved no host at all, and its
  `Phoenix.Token` is per **editor session** rather than per document, so the
  topic and not tenancy was what scoped it. It now resolves its tenant like the
  other two, and every join authorizes the document under it.

  A **connected** LiveView mount was a third until #654 — not because it
  resolved no host, but because it resolved the *client's*: `socket.host_uri` is
  rebuilt from the join payload rather than from a `Host` header, so strict or
  not, the client named its own org. `/live` now carries `connect_info: [:uri]`
  like the other three, and `:assign_current_org` resolves from the socket's own
  request URI, refusing a claim that names a different org
  (`HostMismatchError`). All four socket families now agree: the tenant is the
  one the transport connected on, never the one the payload asks for.

  ## The `:current_org` assign

  `current_org_id/1` reads the resolved org back off a conn/socket's
  `:current_org` assign, and **raises** when that assign is missing rather than
  quietly reading the default org — see `current_org/1`.
  """
  alias KilnCMS.Accounts

  require Logger

  defmodule UnknownHostError do
    @moduledoc """
    Raised when a request's `Host` matches no organization and strict host
    matching is on (`TENANT_STRICT_HOST`, #563).

    Used on the LiveView mount path, where raising is the only way to refuse:
    `plug_status: 404` puts it in the range LiveView's channel turns
    into a client reload rather than a process crash, and on a disconnected
    mount `render_errors` turns it into a plain not-found rather than a 500.
    `KilnCMSWeb.Plugs.SetTenant` answers HTTP requests directly instead of
    raising — see its moduledoc for why.

    The offending host is kept on the struct (and in the message) so the
    operator configuring a new tenant can see which host missed.
    """
    defexception [:host, :message, plug_status: 404]

    @impl true
    def exception(opts) when is_list(opts) do
      host = opts[:host]

      opts
      |> Keyword.put_new(:message, "no organization is configured for host #{inspect(host)}")
      |> then(&struct!(__MODULE__, &1))
    end

    def exception(message) when is_binary(message), do: %__MODULE__{message: message}
  end

  defmodule HostMismatchError do
    @moduledoc """
    Raised when a **connected** LiveView mount claims a host belonging to a
    different organization than the one the socket actually connected on (#654).

    `socket.host_uri` on a connected mount is rebuilt from the client's join
    payload, not from a validated `Host` header, and `check_origin` admits every
    subdomain of the base host — so left alone the client picks its own
    `:current_org`. `KilnCMSWeb.LiveUserAuth.on_mount(:assign_current_org, ...)`
    resolves from `connect_info[:uri]`, the socket's own request URI, and raises
    this when the claim names someone else.

    The comparison is by resolved **org**, not by host string. Two spellings of
    one org's host are not a mismatch, and treating them as one would 404 the
    LiveView surface of any deployment behind a `Host`-rewriting proxy, on an
    IPv6 literal, or on a custom domain reached by its subdomain.

    `plug_status: 404` for the same reason `UnknownHostError` carries it: it puts
    the raise in the range LiveView's channel turns into a client reload
    rather than a process crash, so a probe costs no crash report. It is a 404
    and not a 403 deliberately — the answer to "does this socket belong here" is
    the answer to "is there anything here for you", and the two must not be
    distinguishable.
    """
    defexception [:claimed, :connected, :message, plug_status: 404]

    @impl true
    def exception(opts) when is_list(opts) do
      # Built field by field rather than through `struct!/2` over the opts: an
      # unrecognised key there would raise `KeyError` inside the channel's
      # rescue, and a `KeyError` is a 500 — turning the deliberately quiet 404
      # into a crash report per probe, which is the one thing the status buys.
      claimed = opts[:claimed]
      connected = opts[:connected]

      %__MODULE__{
        claimed: claimed,
        connected: connected,
        message:
          opts[:message] ||
            "LiveView mount claimed host #{inspect(claimed)}, " <>
              "which is not the organization it connected on (#{inspect(connected)})"
      }
    end

    def exception(message) when is_binary(message), do: %__MODULE__{message: message}
  end

  @doc "The current organization id from a conn/socket assign. Raises if unresolved."
  @spec current_org_id(map()) :: Ash.UUID.t()
  def current_org_id(assigns), do: current_org(assigns).id

  @doc """
  The current org struct from a conn/socket's `:current_org` assign.

  Raises `ArgumentError` when the assign is absent. It used to fall back to the
  default org, which made a forgotten `SetTenant` plug or `:assign_current_org`
  on_mount into a silent wrong-tenant read in production instead of a loud
  failure in test (#563). Every conn that reaches a controller has the assign —
  `SetTenant` runs in the endpoint, ahead of the router — and so does every
  `live_session` under `KilnCMSWeb.Router` that mounts the hook.

  It is **not** universal, and callers outside a resolved request must not reach
  for this: a function component rendered from an error page or a mailer
  preview, a `live_isolated/3` test, an AshAdmin route under `dev_routes`. Those
  want `KilnCMS.Accounts.default_org/0` explicitly — see the fallback spelled
  out in `KilnCMSWeb.Layouts`'s console nav.
  """
  @spec current_org(map()) :: Accounts.Organization.t()
  def current_org(%{assigns: %{current_org: %Accounts.Organization{} = org}}), do: org

  def current_org(other) do
    raise ArgumentError, """
    KilnCMSWeb.Tenant.current_org/1 called without a resolved :current_org assign.

    Got: #{describe(other)}

    A conn gets the assign from KilnCMSWeb.Plugs.SetTenant (endpoint-level, so
    it precedes every pipeline); a LiveView socket gets it from the
    {KilnCMSWeb.LiveUserAuth, :assign_current_org} on_mount hook, which every
    live_session must list. Add the missing hook rather than defaulting — a
    default-org read on a tenant site serves the wrong site's content (#563).

    If this caller genuinely has no request context, use
    KilnCMS.Accounts.default_org/0 explicitly.
    """
  end

  # Enough to identify the caller, and nothing more. The argument is normally a
  # conn or a socket, whose `inspect/1` prints request headers — so this message,
  # which ends up in logs and in Sentry, must never carry the value itself.
  defp describe(%{assigns: assigns}) when is_map(assigns),
    do: "a conn/socket whose assigns are #{inspect(Map.keys(assigns))}"

  defp describe(%{__struct__: mod}), do: "a #{inspect(mod)} with no :assigns"
  defp describe(_), do: "a value with no :assigns, so not a conn or socket"

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
  Whether an unresolvable request host is rejected rather than served the
  default org (`TENANT_STRICT_HOST`, #563).

  Read at request time, not compile time, so a release flips it with a restart
  and no rebuild. Defaults to `false`: a single-host install is served entirely
  through the "unknown host → default org" path (bare `localhost`, an IP, the
  load balancer's health-check host), and turning this on there would 404 the
  whole site.
  """
  @spec strict_host?() :: boolean()
  def strict_host?, do: Application.get_env(:kiln_cms, :tenant_strict_host, false)

  @doc """
  Whether this deployment is serving the default org to unrecognized hosts while
  more than one organization exists (#660).

  `TENANT_STRICT_HOST` is off by default, and that is right for the single-host
  install the fallback exists for: with one org, "an unknown Host is served the
  default org" describes the only org there is. The moment a second one exists it
  becomes a live misconfiguration — an unrecognized Host, an IP, or an
  attacker-supplied header is served *another tenant's* content, branding and
  analytics.

  Nothing about that moment is loud. `KilnCMS.Application` checks it at boot, but
  boot happened before the second org existed and may not happen again for
  months; #563 shipped a CHANGELOG note, which helps only an operator reading it
  at the right time. So the same predicate also runs where the decision is made
  (creating the org) and where an operator goes to look (`/editor/system`).

  Deliberately **not** gated on `:multitenancy_enabled`. That flag is a create
  kill switch and nothing in the routing path reads it — an operator with three
  orgs who sets it to `false` to refuse a fourth still has every unrecognized
  Host landing on the default org, and gating on it would silence all three
  warnings for exactly the deployment that needs them.
  """
  @spec strict_host_gap?() :: boolean()
  def strict_host_gap?, do: gap?(org_count())

  @doc """
  The pure half of `strict_host_gap?/0`: the verdict for an already-known count.

  Split out to be testable. `Organization` has no destroy action, so a test
  cannot get the table below the seeded default org and the `0`/`1` cases are
  unreachable through the database — which is how a threshold of `> 0` would
  otherwise sit here unnoticed, passing every test that exists.
  """
  @spec gap?(non_neg_integer() | :unknown) :: boolean()
  def gap?(count) do
    strict_host?() != true and is_integer(count) and count > 1
  end

  @doc """
  How many organizations exist, or `:unknown` if the question cannot be answered.

  Total by construction. One caller renders a page, one runs after an
  organization's create, and one runs during boot — a count that raised in any of
  them would turn an advisory into a worse failure than the one it describes. A
  database that is not up yet is not evidence of a misconfiguration.
  """
  @spec org_count() :: non_neg_integer() | :unknown
  def org_count do
    case Ash.count(KilnCMS.Accounts.Organization, authorize?: false) do
      {:ok, n} -> n
      _error -> :unknown
    end
  rescue
    _error -> :unknown
  end

  @doc """
  Resolve the organization for a request host.

  `{:ok, org}` for a host that matches an org (subdomain, custom domain, or the
  canonical base host). For anything else — a bare hostname, `localhost`, an IP
  literal, an attacker-supplied `Host` — this is `{:ok, default_org}` normally
  and `:error` when `strict_host?/0` is on.

  The canonical base host is never refused, even under strict matching — the
  deployment must always answer on its own name. Every lookup below collapses a
  failed read to `nil`, so without this clause a default org whose seed row is
  missing, or a Postgres restart caught mid-request, would 404 the apex. Note
  the clause covers *only* the apex: a tenant subdomain or custom domain during
  the same outage still gets `:error`, since nothing here can tell "no such org"
  apart from "could not ask".

  Callers that can reject the request should use this and turn `:error` into a
  404 or a refused socket; `resolve_org/1` is the never-failing form for those
  that cannot.
  """
  @spec fetch_org(String.t() | nil) :: {:ok, Accounts.Organization.t()} | :error
  def fetch_org(host) do
    cond do
      org = known_org(host) -> {:ok, org}
      strict_host?() and not canonical_host?(host) -> :error
      true -> {:ok, default_org()}
    end
  end

  @doc """
  `fetch_org/1` for a socket's connect info, whose host lives at `[:uri, :host]`.

  Sockets bypass the plug pipeline, so each one has to resolve its own tenant,
  and all three did it by hand-writing the same `get_in/2` — three copies of one
  accessor, and of the reasoning about what an absent host means. A missing host
  (no `connect_info`, as in a bare test connect) resolves to the default org, or
  is refused under `TENANT_STRICT_HOST` (#563), exactly as a request whose
  `Host` matches nothing would be.
  """
  @spec fetch_org_from_connect_info(map()) :: {:ok, Accounts.Organization.t()} | :error
  def fetch_org_from_connect_info(connect_info) do
    fetch_org(get_in(connect_info, [:uri, Access.key(:host)]))
  end

  defp canonical_host?(host) when is_binary(host), do: normalize(host) == base_host()
  defp canonical_host?(_), do: false

  @doc """
  Resolve the organization for a request host, always returning an org struct
  (falls back to the default org even under `strict_host?/0`), so callers never
  have to handle `nil`.
  """
  @spec resolve_org(String.t() | nil) :: Accounts.Organization.t()
  def resolve_org(host), do: known_org(host) || default_org()

  # `Accounts.default_org/0` reads the seed row, which can miss on a
  # broken/uninitialized install, so a synthetic default-id-only struct is the
  # final fallback rather than propagating a `nil` for callers to crash on.
  defp default_org,
    do: Accounts.default_org() || %Accounts.Organization{id: Accounts.default_org_id()}

  # The org this host names, or `nil` if it names none.
  #
  # Both outcomes are cached, in `KilnCMS.Cache.Hosts` — a cache of its own, not
  # the content one. That separation is what makes caching a miss safe: a flood
  # of distinct attacker Host headers under `*.<base>` evicts only other host
  # entries, never hot published pages (#659). Before it, `nil` was deliberately
  # never committed, so every unknown host cost a database round trip for ever,
  # unmetered — tenant refusal halts in the endpoint above every rate limiter
  # (#336 review, resolution-cache DoS).
  #
  # A miss is held for one minute against five for a hit, so a host configured
  # moments after someone probed it starts working promptly. See that module for
  # what a negative entry does and does not cost.
  defp known_org(host) when is_binary(host) do
    case normalize(host) do
      "" -> nil
      host -> resolve_cached(host)
    end
  end

  defp known_org(_), do: nil

  # Hostnames are case-insensitive (RFC 3986) and `socket.host_uri`/`conn.host`
  # aren't normalized, so downcase before matching/caching — otherwise
  # `Acme.Example.com` fails the suffix/slug match and mis-resolves to the
  # default org, and case variants fragment the cache (#336 review).
  #
  # The trailing dot of a rooted FQDN goes too. `acme.example.com.` is what a
  # browser sends when the user types the rooted form, and it names exactly the
  # same host — but it fails every suffix and equality test below, so without
  # this it resolves to the default org (before #563) or 404s the tenant on
  # their own domain (after).
  defp normalize(host), do: host |> String.trim_trailing(".") |> String.downcase()

  defp resolve_cached(host) do
    KilnCMS.Cache.Hosts.fetch(host, fn -> resolve_known(host) end)
  end

  # A real org (by subdomain slug or custom domain), or the default org when the
  # host IS the canonical base host. `nil` for anything else — which `Cache.Hosts`
  # stores as its own `:unresolved` sentinel, because Cachex uses `nil` for "not
  # present" and a cached miss has to be distinguishable from never having asked.
  #
  # This function is the ONLY thing that writes a negative entry, and it only
  # runs on a real lookup that really found nothing. So a cached miss can never
  # refuse a host the database would have resolved — the property that separates
  # this from bounding the work with a rate limit, which cannot tell a flood
  # from a legitimate request behind the same address.
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

  Normalized the same way an incoming host is, because it is compared against
  one. `runtime.exs` strips a scheme and trailing slash off `PHX_HOST` but not
  case, so `PHX_HOST=Example.com` would otherwise match no host at all: with
  strict matching off that is invisible (everything lands on the default org),
  and with it on the apex and every tenant subdomain 404.
  """
  @spec base_host() :: String.t()
  def base_host do
    (Application.get_env(:kiln_cms, :tenant_base_host) ||
       get_in(Application.get_env(:kiln_cms, KilnCMSWeb.Endpoint, []), [:url, :host]) ||
       "localhost")
    |> normalize()
  end
end
