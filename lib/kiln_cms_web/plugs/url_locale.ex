defmodule KilnCMSWeb.Plugs.UrlLocale do
  @moduledoc """
  Takes the request locale from the URL alone (#2595): the path prefix
  `Plugs.SetLocale` stripped (`conn.assigns.path_locale`), or the site's default
  locale when there was none. The session preference is never consulted.

  For the public delivery surfaces whose responses a shared cache may store:
  published pages and posts, the blog index, the event index (HTML and
  `/<plural>/index.json`), the stock home page, a form's own page and its
  embed document. The rest of `ContentController` (search, which is
  `private, no-cache`; the `no-store` 404; the lock and teaser pages) follows
  the same rule for consistency, not because a cache could store them: a
  reader's language is the one in the address they are on.

  `SetLocale` falls back to the session's locale on an unprefixed URL, which
  is right for the console and the sign-in screens, but a `public` response
  built from it would be stored under the unprefixed URL and handed to every
  later visitor. The session is not on the cache key, and
  `Vary: Cookie` is no fix: every browser carries a session cookie, so it
  would split the cache per visitor.

  It overrides `conn.assigns.locale` and the Gettext locale that `SetLocale`
  set, so templates, the layout and `gettext/1` all agree. Plugged per
  controller rather than in the `:delivery` pipeline, which also serves
  surfaces that follow the session on purpose (`MembershipLive`).

  `locale/1` is the same rule as a function, for code that must not depend on
  whether this plug ran — the response's cache headers, say.
  """
  @behaviour Plug

  import Plug.Conn

  alias KilnCMS.I18n

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    locale = locale(conn)
    Gettext.put_locale(KilnCMSWeb.Gettext, locale)
    assign(conn, :locale, locale)
  end

  @doc """
  The locale the URL names: the stripped path prefix, else the default locale.
  """
  @spec locale(Plug.Conn.t()) :: String.t()
  def locale(conn), do: conn.assigns[:path_locale] || I18n.default_locale()
end
