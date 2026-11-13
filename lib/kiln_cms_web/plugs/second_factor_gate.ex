defmodule KilnCMSWeb.Plugs.SecondFactorGate do
  @moduledoc """
  A browser request from an account its site holds for a second factor it has
  not set up (#2247) goes to `/account/two-factor` before anything else. The
  decision is `KilnCMSWeb.SecondFactorGate.held?/3`'s, on the site the request
  resolved to. Two modes:

    * `:redirect` — on `:browser`, after `IdleTimeout, :session` (a session
      that is no longer good is already signed out, and goes to sign-in
      instead). A held account's request is answered `302` to the setup page,
      with the path it asked for as `return_to` on a `GET`. It **writes no
      session, no flash and no cookie**, and the redirect is `private,
      no-store`: `:browser` serves the public site, whose pages are
      `cache-control: public` (#699), and neither a `Set-Cookie` nor a
      redirect meant for one signed-in account may be stored by a shared
      cache and handed to every visitor.
    * `:read_only` — on `:media_transform`: an image cannot follow a redirect,
      so a held account is served as anonymous there (a gated image is
      refused, a public one served).

  ## What a held account can still reach

  The exempt list below, by method and path. Everything outside `:browser`
  is untouched by construction: the sign-in, sign-out, second-factor prompt,
  `/auth/*`, invitation and unlock routes (`:browser_auth`), static files,
  health checks, webhooks, federation and every API-key surface.

    * `/account/two-factor` — where it is sent;
    * `POST /billing/portal` and `GET /editor/account/export.json` — a
      reader held by a site that requires everyone keeps their billing and
      their data export (owner decision 4);
    * `/locale/:locale`, `/access-denied`, `/developers`, `/api` — pages
      that read nothing of the account;
    * `/setup` — the first-run wizard, which sends a signed-in visitor away
      on its own;
    * `/preview/**` and `/newsletter/**` — authorized by their own tokens,
      not by the session.
  """
  @behaviour Plug

  import Plug.Conn

  alias KilnCMSWeb.SecondFactorGate

  @impl true
  def init(mode) when mode in [:redirect, :read_only], do: mode

  @impl true
  def call(conn, mode) do
    if exempt?(conn) or not held?(conn), do: conn, else: act(conn, mode)
  end

  defp held?(conn) do
    SecondFactorGate.held?(conn.assigns[:current_user], org_id(conn), fresh?: true)
  end

  defp act(conn, :read_only), do: assign(conn, :current_user, nil)

  defp act(conn, :redirect) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> Phoenix.Controller.redirect(to: SecondFactorGate.setup_path(return_to(conn)))
    |> halt()
  end

  # Only a page someone navigated to is worth returning to; a form post is
  # not repeatable from a link.
  defp return_to(%Plug.Conn{method: "GET"} = conn) do
    case conn.query_string do
      "" -> conn.request_path
      query -> conn.request_path <> "?" <> query
    end
  end

  defp return_to(_conn), do: nil

  @doc """
  Whether a request is one a held account may still make. Public so the
  exempt list is pinned by a test, method and all.
  """
  @spec exempt?(Plug.Conn.t()) :: boolean()
  def exempt?(%Plug.Conn{method: method, path_info: path_info}), do: exempt?(method, path_info)

  defp exempt?(_method, ["account", "two-factor"]), do: true
  defp exempt?("POST", ["billing", "portal"]), do: true
  defp exempt?("GET", ["editor", "account", "export.json"]), do: true
  defp exempt?(_method, ["locale", _locale]), do: true
  defp exempt?("GET", ["access-denied"]), do: true
  defp exempt?("GET", ["developers"]), do: true
  defp exempt?("GET", ["api"]), do: true
  defp exempt?(_method, ["setup"]), do: true
  defp exempt?(_method, ["preview" | _rest]), do: true
  defp exempt?(_method, ["newsletter" | _rest]), do: true
  defp exempt?(_method, _path_info), do: false

  defp org_id(conn) do
    case conn.assigns[:current_org] do
      %{id: id} when is_binary(id) -> id
      _none -> nil
    end
  end
end
