defmodule ShowcaseWeb.Plugs.Locale do
  @moduledoc """
  Resolves the active content locale for the request and stashes it in the
  session, so both controllers and LiveViews can read it back. Defaults to the
  KilnCMS default locale until the visitor picks one via `/locale/:locale`.
  """
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    locale = get_session(conn, "locale") || Showcase.Kiln.locale()

    conn
    |> put_session("locale", locale)
    |> assign(:locale, locale)
  end
end
