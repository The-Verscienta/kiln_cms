defmodule ShowcaseWeb do
  @moduledoc """
  Entrypoint definitions for the web layer (`use ShowcaseWeb, :live_view` etc.).
  """

  def static_paths, do: ~w(assets favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:html, :json],
        layouts: [html: ShowcaseWeb.Layouts]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView, layout: {ShowcaseWeb.Layouts, :app}

      # Make the active + available content locales available to every LiveView
      # (and thus the app layout's locale switcher).
      on_mount ShowcaseWeb.LocaleHook

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      import Phoenix.Component
      alias Phoenix.LiveView.JS
      alias ShowcaseWeb.Layouts

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: ShowcaseWeb.Endpoint,
        router: ShowcaseWeb.Router,
        statics: ShowcaseWeb.static_paths()
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
