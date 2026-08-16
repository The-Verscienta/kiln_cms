defmodule KilnCMSWeb.Plugs.ConsoleHost do
  @moduledoc """
  Serve the editor console from a host no tenant controls (#740, step 2).

  Off unless `KILN_CONSOLE_HOST` (`config :kiln_cms, :console_host`) is set;
  then, ahead of the router:

    * a **console** route (`KilnCMSWeb.Surface`) requested on any other host is
      not served there — a `GET`/`HEAD` is redirected to the same path on the
      console host (an editor who typed `/editor` on the site gets where they
      meant), anything else is a 404;
    * a **delivery** route requested on the console host is a 404 — the
      console host serves no tenant content, so nothing a tenant can put on a
      page is ever same-origin with it (`/` on the console host redirects to
      `/editor`, since that is what someone typing the bare host wants);
    * **shared** routes are served on both.

  That is the whole security boundary: with it, delivery script is
  cross-origin to the console, so the console's cookies are not attached to
  its requests and its DOM is not reachable. The classification is the
  router's (`Surface`), pinned by a drift test, rather than a prefix guess —
  see that module for why a prefix guess is a boundary that is nearly right.

  ## What this does not do (and why it ships anyway)

  Org resolution is still host-derived (`KilnCMSWeb.Tenant`), and the console
  host names no tenant. `Tenant.fetch_org/1` therefore resolves the console
  host to the **default org** — never refused, even under `TENANT_STRICT_HOST`
  — so on a single-org deployment the console works unchanged, and that is
  where #490 code injection is most used, which is why this ships before the
  session-derived resolution a multi-org console needs. On a multi-org
  deployment the console host reaches only the default org's console; the
  per-tenant hosts keep working for readers, and a tenant admin still signs in
  on their own host — where the console routes now redirect here. Filed as the
  follow-up the #740 investigation named (step 3).

  Cookies are per host, so the console gets its own session automatically;
  `CHECK_ORIGINS` (LiveView's origin check) must include the console host, and
  `docs/multi-tenancy.md` says so.
  """
  @behaviour Plug

  import Plug.Conn

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

  @doc "Whether the request arrived on the console host."
  @spec on_console_host?(Plug.Conn.t(), String.t() | nil) :: boolean()
  def on_console_host?(_conn, nil), do: false
  def on_console_host?(conn, host), do: String.downcase(conn.host || "") == host

  @doc """
  The URL of `path` on the console host — the endpoint's scheme and port with
  the host swapped, so a deployment behind TLS termination or a non-default
  port keeps working.
  """
  @spec console_url(String.t()) :: String.t()
  def console_url(path) do
    KilnCMSWeb.Endpoint.struct_url()
    |> Map.put(:host, console_host())
    |> Map.put(:path, path)
    |> URI.to_string()
  end

  defp gate(conn, on_console?) do
    case {surface(conn), on_console?} do
      # A console route on a tenant host: send the browser to the console.
      {:console, false} when conn.method in ["GET", "HEAD"] ->
        conn
        |> Phoenix.Controller.redirect(external: console_url(path_with_query(conn)))
        |> halt()

      {:console, false} ->
        not_found(conn)

      # The bare console host: the console is what they want.
      {:delivery, true} when conn.request_path == "/" ->
        conn
        |> Phoenix.Controller.redirect(external: console_url("/editor"))
        |> halt()

      # Tenant content is never served on the console host.
      {:delivery, true} ->
        not_found(conn)

      _served_here ->
        conn
    end
  end

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
