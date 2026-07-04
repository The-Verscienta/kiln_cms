defmodule ShowcaseWeb.LocaleHook do
  @moduledoc """
  LiveView `on_mount` hook that assigns the active content locale (from the
  session) and the set of available locales (from KilnCMS `GET /api/locales`),
  so the app layout can render a working locale switcher.
  """
  import Phoenix.Component

  def on_mount(:default, _params, session, socket) do
    locale = session["locale"] || Showcase.Kiln.locale()

    locales =
      case Showcase.Kiln.locales() do
        {:ok, %{locales: locales}} -> locales
        _ -> [locale]
      end

    {:cont, socket |> assign(:locale, locale) |> assign(:locales, locales)}
  end
end
