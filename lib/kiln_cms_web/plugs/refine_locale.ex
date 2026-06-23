defmodule KilnCMSWeb.Plugs.RefineLocale do
  @moduledoc """
  Refines the request locale from the session preference and the browser's
  `Accept-Language`, for routes that didn't carry an explicit `/<locale>/` prefix.

  Runs in the `:browser` pipeline (after the session is fetched), so the public
  site — the home page, chrome, and unprefixed content — localizes for anonymous
  visitors by browser language, and for anyone who picked a locale via the
  switcher. A path prefix still wins: `KilnCMSWeb.Plugs.SetLocale` pins those and
  this plug leaves them untouched.

  Precedence: path prefix › session › `Accept-Language` › default.
  """
  @behaviour Plug

  import Plug.Conn

  alias KilnCMS.I18n

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{assigns: %{locale_pinned: true}} = conn, _opts), do: conn

  def call(conn, _opts) do
    locale = session_locale(conn) || header_locale(conn) || I18n.default_locale()
    Gettext.put_locale(KilnCMSWeb.Gettext, locale)
    assign(conn, :locale, locale)
  end

  defp session_locale(conn) do
    locale = get_session(conn, "locale")
    if is_binary(locale) and I18n.supported?(locale), do: locale
  end

  defp header_locale(conn) do
    case get_req_header(conn, "accept-language") do
      [header | _] -> I18n.negotiate(header)
      _ -> nil
    end
  end
end
