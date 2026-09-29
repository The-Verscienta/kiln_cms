defmodule KilnCMSWeb.Plugs.ConsoleHost do
  @moduledoc """
  Serve the editor console from hosts no tenant controls (#740, step 2; #1688).

  Off unless `KILN_CONSOLE_HOST` (`config :kiln_cms, :console_host`) is set;
  then, ahead of the router:

    * a **console** route (`KilnCMSWeb.Surface`) requested on any other host is
      not served there — a `GET`/`HEAD` is redirected to the same path on the
      requesting org's console host (an editor who typed `/editor` on their
      site gets where they meant), anything else is a 404;
    * a **delivery** route requested on a console host is a 404 — console
      hosts serve no tenant content, so nothing a tenant can put on a page is
      ever same-origin with a console (`/` on a console host redirects to
      `/editor`, since that is what someone typing the bare host wants);
    * **shared** routes are served on both.

  That is the whole security boundary: with it, delivery script is
  cross-origin to every console, so a console's cookies are not attached to
  its requests and its DOM is not reachable. The classification is the
  router's (`Surface`), pinned by a drift test, rather than a prefix guess —
  see that module for why a prefix guess is a boundary that is nearly right.

  ## One console origin per organization (#1688)

  The bare console host is the **default org's** console. Every other org's
  console is `<slug>.<console host>` — a host of its own, derived from the
  slug, which `KilnCMSWeb.Tenant` resolves to that org exactly as it resolves
  `<slug>.<base host>`. So org resolution stays host-derived (the invariant
  every socket and `:assign_current_org` rely on), a console route on an org's
  site host redirects to *that org's* console host, and no two orgs' consoles
  share an origin either. Decision record 0011 argues this against one shared,
  session-aware console host.

  Cookies are per host (and `__Host-`-prefixed in production), so each console
  host gets its own session automatically. The endpoint's `check_origin`
  admits the console host and its subdomains (`config/runtime/prod/web.exs`),
  and passkey ceremonies accept them as origins (`KilnCMS.Accounts.WebAuthn`)
  — which only works while the console host sits under `PHX_HOST`, the
  passkeys' RP ID; see `passkey_capable?/0`.
  """
  @behaviour Plug

  import Plug.Conn

  alias KilnCMS.Accounts
  alias KilnCMSWeb.Surface

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case console_host() do
      nil -> conn
      host -> gate(conn, on_console_host?(conn, host))
    end
  end

  @doc "The configured console host (normalized), or `nil` when the gate is off."
  @spec console_host() :: String.t() | nil
  def console_host do
    case Application.get_env(:kiln_cms, :console_host) do
      host when is_binary(host) ->
        case host |> String.trim() |> String.downcase() do
          "" -> nil
          normalized -> normalized
        end

      _ ->
        nil
    end
  end

  @doc """
  Whether the request arrived on a console host — the console host itself or
  one org's console host under it (`<slug>.<console host>`).
  """
  @spec on_console_host?(Plug.Conn.t(), String.t() | nil) :: boolean()
  def on_console_host?(_conn, nil), do: false
  def on_console_host?(conn, console), do: console_host_name?(conn.host, console)

  @doc """
  Whether `host` is a console host: the configured one, or a one-label
  subdomain of it. `false` when the gate is off.
  """
  @spec console_host_name?(String.t() | nil) :: boolean()
  def console_host_name?(host), do: console_host_name?(host, console_host())

  defp console_host_name?(host, console) when is_binary(host) and is_binary(console) do
    normalize(host) == console or not is_nil(org_label(host, console))
  end

  defp console_host_name?(_host, _console), do: false

  @doc """
  The org slug an org's console host names — `"acme"` for
  `acme.<console host>` — or `nil` for the bare console host, a deeper
  subdomain, any other host, or when the gate is off.
  """
  @spec org_label(String.t() | nil) :: String.t() | nil
  def org_label(host), do: org_label(host, console_host())

  defp org_label(host, console) when is_binary(host) and is_binary(console) do
    host = normalize(host)
    suffix = "." <> console

    # A multi-label prefix (`a.b.console.example.com`) names no org, as it
    # names none under the base host.
    with true <- String.ends_with?(host, suffix),
         label when label != "" <- String.replace_suffix(host, suffix, ""),
         false <- String.contains?(label, ".") do
      label
    else
      _ -> nil
    end
  end

  defp org_label(_host, _console), do: nil

  @doc """
  The console host for `org`: the bare console host for the default org (or no
  org), `<slug>.<console host>` for any other. `nil` when the gate is off.
  """
  @spec console_host_for(Accounts.Organization.t() | nil) :: String.t() | nil
  def console_host_for(org) do
    case {console_host(), org} do
      {nil, _org} ->
        nil

      {console, %Accounts.Organization{id: id, slug: slug}} when is_binary(slug) and slug != "" ->
        if id == Accounts.default_org_id(), do: console, else: "#{slug}.#{console}"

      {console, _default_or_unresolved} ->
        console
    end
  end

  @doc """
  The URL of `path` on a console host — the endpoint's scheme and port with the
  host swapped, so a deployment behind TLS termination or a non-default port
  keeps working. With an org, that org's console host (`console_host_for/1`);
  without one, the bare console host.
  """
  @spec console_url(String.t(), Accounts.Organization.t() | nil) :: String.t()
  def console_url(path, org \\ nil), do: url_on(console_host_for(org), path)

  @doc """
  Whether passkeys can work on the console hosts. The browser accepts the
  deployment's RP ID — the `PHX_HOST` host, see `KilnCMS.Accounts.WebAuthn` —
  only on an origin whose host is it or ends in `.<it>`, so a console host
  outside `PHX_HOST` gets no passkey sign-in at all. `true` when the gate is
  off. Kiln warns at boot when this is `false`.
  """
  @spec passkey_capable?() :: boolean()
  def passkey_capable? do
    case console_host() do
      nil -> true
      console -> under?(console, normalize(KilnCMSWeb.Endpoint.struct_url().host || ""))
    end
  end

  defp under?(_host, ""), do: false
  defp under?(host, parent), do: host == parent or String.ends_with?(host, "." <> parent)

  defp gate(conn, on_console?) do
    case {surface(conn), on_console?} do
      # A console route on a site host: send the browser to *that org's*
      # console host. `SetTenant` runs ahead of this plug in the endpoint, so
      # the org is the one the request's own host resolved to.
      {:console, false} when conn.method in ["GET", "HEAD"] ->
        conn
        |> Phoenix.Controller.redirect(
          external: console_url(path_with_query(conn), conn.assigns[:current_org])
        )
        |> halt()

      {:console, false} ->
        not_found(conn)

      # The bare host: the console is what they want — on the console host the
      # request is already on, which is its org's.
      {:delivery, true} when conn.request_path == "/" ->
        conn
        |> Phoenix.Controller.redirect(external: url_on(normalize(conn.host), "/editor"))
        |> halt()

      # Tenant content is never served on a console host.
      {:delivery, true} ->
        not_found(conn)

      _served_here ->
        conn
    end
  end

  defp url_on(host, path) do
    KilnCMSWeb.Endpoint.struct_url()
    |> Map.put(:host, host)
    |> Map.put(:path, path)
    |> URI.to_string()
  end

  # Hostnames are case-insensitive and a rooted FQDN's trailing dot names the
  # same host — the normalization `KilnCMSWeb.Tenant` applies before matching.
  defp normalize(host), do: host |> String.trim_trailing(".") |> String.downcase()

  # `route_info/4` matches without dispatching. `:error` is an unmatched path,
  # which the router will 404 (or the delivery catch-all will take) — either
  # way delivery, and delivery on a tenant host is served.
  defp surface(conn) do
    case Phoenix.Router.route_info(KilnCMSWeb.Router, conn.method, conn.request_path, conn.host) do
      :error -> :delivery
      route -> Surface.of(route)
    end
  end

  defp path_with_query(%{request_path: path, query_string: ""}), do: path
  defp path_with_query(%{request_path: path, query_string: query}), do: path <> "?" <> query

  defp not_found(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "Not found")
    |> halt()
  end
end
