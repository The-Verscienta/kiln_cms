defmodule KilnCMSWeb.Plugs.LiveLocalePrefix do
  @moduledoc """
  Moves a locale path prefix on a LiveView page into the session (#1699).

  `KilnCMSWeb.Plugs.SetLocale` strips `/es` from `/es/sign-in` in the endpoint,
  so the router matches `/sign-in` and the dead render can honour the prefix.
  A LiveView cannot keep that URL, though. Its channel join re-matches the
  browser's own `window.location` (`/es/sign-in`) against the router, which has
  no prefixed routes, and refuses the join as unauthorized; the client answers
  by reloading the same URL. The page never connected, so the sign-in form never
  worked. The LiveView process also never sees the prefix: `:restore_locale`
  reads the locale from the session, so the page rendered English under
  `lang="en"`.

  So a prefixed GET for a LiveView route records the prefix as the session
  locale (the same key `KilnCMSWeb.LocaleController` writes) and redirects to the
  unprefixed path. The reader's choice then holds for the LiveView, its live
  navigations, and every controller page after it, such as `/sign-in/verify`.

  The locale is `SetLocale`'s `conn.assigns.path_locale`, so which segments
  count as a locale is decided in one place, `KilnCMS.I18n.supported?/1`, and
  `/es` on its own stays a slug (a prefix needs a segment after it).

  Only live routes: the router puts `:phoenix_live_view` on the conn when it
  matches one, before the pipeline runs. Controller pages keep their prefixed
  URLs; public delivery uses them as canonical and `hreflang` links.
  """
  @behaviour Plug

  import Plug.Conn

  alias KilnCMSWeb.SafeRedirect

  @impl true
  def init(opts), do: opts

  @impl true
  def call(
        %Plug.Conn{
          method: method,
          assigns: %{path_locale: locale},
          private: %{phoenix_live_view: _}
        } = conn,
        _opts
      )
      when method in ["GET", "HEAD"] and is_binary(locale) do
    path = unprefixed_path(conn)

    # `Phoenix.Controller.redirect/2` raises on a backslash anywhere in a local
    # path, and a path param (`/preview/:token/live`) can carry one. Leave such a
    # request as it was rather than turn it into a 500.
    if SafeRedirect.safe_local_path?(path) and not String.contains?(path, "\\") do
      conn
      |> put_session("locale", locale)
      |> Phoenix.Controller.redirect(to: path)
      |> halt()
    else
      conn
    end
  end

  def call(conn, _opts), do: conn

  defp unprefixed_path(%Plug.Conn{request_path: path, query_string: ""}), do: path
  defp unprefixed_path(%Plug.Conn{request_path: path, query_string: qs}), do: path <> "?" <> qs
end
