defmodule KilnCMSWeb.Plugs.SecondFactorGate do
  @moduledoc """
  A browser request from an account its site holds for a second factor it has
  not set up (#2247) goes to `/account/two-factor` before anything else. The
  decision is `KilnCMSWeb.SecondFactorGate.held?/3`'s, on the site the request
  resolved to. Two modes:

    * `:redirect` — on `:browser`, after `IdleTimeout, :session` (a session
      that is no longer good is already signed out, and goes to sign-in
      instead). A held account's request is answered `302` to the setup page,
      with the path it asked for as `return_to` on a `GET` — or, on a tenant
      site host, to the main host's setup page, which is not served on a site
      host (`SecondFactorGate.setup_host?/1`). It **writes no
      session, no flash and no cookie**, and the redirect is `private,
      no-store`: `:browser` serves the public site, whose pages are
      `cache-control: public` (#699), and neither a `Set-Cookie` nor a
      redirect meant for one signed-in account may be stored by a shared
      cache and handed to every visitor.
    * `:read_only` — on `:media_transform`: an image cannot follow a redirect,
      so a held account is served as anonymous there (a gated image is
      refused, a public one served).

  ## What a held account can still reach

  The exempt list below, by method and path. A passkey-only account's
  password-only session (`SecondFactorGate.passkey_step_up_owed?/3`) is sent
  to the passkey prompt at `/sign-in/verify` instead, and keeps only the
  pages that read nothing of the account: not the setup page, billing or the
  export. Everything outside `:browser`
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
    cond do
      account_free?(conn) -> conn
      step_up_owed?(conn) -> step_up(conn, mode)
      exempt?(conn) or not held?(conn) -> conn
      true -> act(conn, mode)
    end
  end

  # A passkey-only account past its deadline whose session never passed the
  # passkey (signed in with the password before the deadline, or restored by
  # a remember-me cookie): password-only access the site no longer accepts.
  # It goes to the passkey prompt, and the setup page, billing and the export
  # are not exempt from that: the account does hold a factor, and this
  # session has not shown it.
  defp step_up_owed?(conn) do
    SecondFactorGate.passkey_step_up_owed?(conn.assigns[:current_user], org_id(conn), conn)
  end

  defp step_up(conn, :read_only), do: assign(conn, :current_user, nil)

  defp step_up(conn, :redirect) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> Phoenix.Controller.redirect(to: "/sign-in/verify")
    |> halt()
  end

  defp held?(conn) do
    SecondFactorGate.held?(conn.assigns[:current_user], org_id(conn), fresh?: true)
  end

  defp act(conn, :read_only), do: assign(conn, :current_user, nil)

  defp act(conn, :redirect) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> Phoenix.Controller.redirect(
      SecondFactorGate.redirect_opts(SecondFactorGate.setup_location(conn.host, return_to(conn)))
    )
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
  defp exempt?(method, path_info), do: account_free?(method, path_info)

  # Pages that read nothing of the account, or are authorized by their own
  # tokens: exempt from both holds.
  defp account_free?(%Plug.Conn{method: method, path_info: path_info}),
    do: account_free?(method, path_info)

  defp account_free?(_method, ["locale", _locale]), do: true
  defp account_free?("GET", ["access-denied"]), do: true
  defp account_free?("GET", ["developers"]), do: true
  defp account_free?("GET", ["api"]), do: true
  defp account_free?(_method, ["setup"]), do: true
  defp account_free?(_method, ["preview" | _rest]), do: true
  defp account_free?(_method, ["newsletter" | _rest]), do: true
  defp account_free?(_method, _path_info), do: false

  defp org_id(conn) do
    case conn.assigns[:current_org] do
      %{id: id} when is_binary(id) -> id
      _none -> nil
    end
  end
end
