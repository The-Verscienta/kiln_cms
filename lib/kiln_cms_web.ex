defmodule KilnCMSWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use KilnCMSWeb, :controller
      use KilnCMSWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  # robots.txt is served dynamically by SitemapController (so it can reference
  # the environment's sitemap URL). `embed.js` (host-page snippet),
  # `embed-frame.js` (iframe height reporter) and `bridge.js` (the visual-editing
  # overlay SDK, #355) are hand-written and live at `priv/static/`, outside the
  # gitignored `assets/` build output. `sw.js` is the editor PWA's service worker
  # and MUST stay at the root, since a service worker's default scope is its own
  # directory and the app spans `/editor`, `/media` and `/sign-in`. The manifest
  # and the offline fallback are both per-org and served by
  # `KilnCMSWeb.ManifestController` / `KilnCMSWeb.OfflineController` (#629), not
  # from here — `offline.html` was a static file until then, and listing it here
  # again would shadow the route with a stale unbranded copy.
  def static_paths,
    do: ~w(assets fonts images favicon.ico embed.js embed-frame.js bridge.js sw.js)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
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
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: KilnCMSWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      # Attached to the LiveView module rather than to a `live_session`, because
      # the router's hooks are exactly what a url-less join skips (#688). A hook
      # declared here survives that, and refuses the join. The join budget
      # (#1183) sits FIRST so a join the guard refuses is still charged.
      on_mount KilnCMSWeb.LiveJoinBudget
      on_mount KilnCMSWeb.LiveRouteGuard

      # Appends a catch-all `handle_event/3` after the module body, so a pushed
      # event whose payload arrived in a shape no clause matches is ignored
      # rather than crashing the view (#764). Must be `@before_compile`, not a
      # clause injected here — a catch-all written at the top of a module
      # shadows every real handler below it.
      use KilnCMSWeb.MalformedEvent

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

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: KilnCMSWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import KilnCMSWeb.CoreComponents

      # Common modules used in templates
      alias KilnCMSWeb.Layouts
      alias Phoenix.LiveView.JS

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: KilnCMSWeb.Endpoint,
        router: KilnCMSWeb.Router,
        statics: KilnCMSWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
