defmodule KilnCMSWeb.Surface do
  @moduledoc """
  Which **surface** a route belongs to — the editor console, public delivery, or
  both — as a fact the router owns (#740, step 1).

  `https://acme.example/editor` and `https://acme.example/` are the same
  origin, so any script that runs on a tenant's public site (a stored XSS in
  delivery; #490's supported code injection) is same-origin with the console:
  it can `fetch("/editor/…", {credentials: "same-origin"})` in the browser of
  a signed-in editor who loads a public page. The fix is to serve the console
  from a host no tenant controls (`KilnCMSWeb.Plugs.ConsoleHost`, step 2) —
  and that needs "is this a console route?" answered deliberately, because it
  **cannot be answered by path prefix**: `api`, `auth`, `media` and `editor`
  legitimately begin routes on both sides (`/api/auth/sign_in` is a delivery
  credential endpoint; `/media/<id>/stream` serves public assets; the
  `/:slug` and `/*path` catch-alls match anything). A prefix gate would either
  break delivery or leave console paths reachable, and a boundary that is
  *nearly* right reads as protection while not being it.

  So every route is classified here, from what the router already knows about
  it — its `live_session`, its pipelines, its exact pattern — and
  `test/kiln_cms_web/surface_test.exs` pins the full console and shared lists
  so a new route lands in the right column on purpose, not by default.

  ## The three surfaces

    * `:console` — served **only** on the console host once one is configured:
      every LiveView in the `:editor_routes` / `:admin_routes` /
      `:plugin_editor_routes` sessions, the `/editor/**` export controllers,
      and the dev-only tools (`/dev`, `/admin`).
    * `:shared` — served on both, because both need it: the sign-in and
      account family (a *member* signs in on the public site for gated content
      — #337 — and an editor signs in on the console; cookies are per host, so
      the two are separate sessions), the headless APIs (`/api/**`, `/gql`,
      `/mcp` — bearer-authenticated, and the console's own JS calls them),
      previews, media download/stream (the console's media library plays
      through them), the PWA manifest, the locale switch and the health probes.
    * `:delivery` — everything else: the tenant's public pages, forms, feeds,
      newsletter, billing handoffs, federation, membership.

  A route that matches nothing is delivery — the router's own catch-alls make
  every unmatched path delivery already.
  """

  @type surface :: :console | :shared | :delivery

  @console_live_sessions [:editor_routes, :admin_routes, :plugin_editor_routes]

  # Exact patterns and prefixes shared by both hosts. Patterns are the router's
  # own (`/preview/:token`), compared literally against `route_info/4`'s `:route`.
  @shared_exact ~w(/account /locale/:locale /up /ready /gql /manifest.webmanifest /offline.html
                   /media/:id/download /media/:id/stream)
  @shared_prefixes ~w(/api /mcp /preview /auth /sign-in /sign-out /reset /register
                      /password-reset /confirm_new_user /magic_link)

  @doc """
  Classify one route, as returned by `Phoenix.Router.route_info/4` (or an entry
  of `Router.__routes__/0`, whose `:path` is read when `:route` is absent).
  """
  @spec of(map()) :: surface()
  def of(route) when is_map(route) do
    pattern = Map.get(route, :route) || Map.get(route, :path) || "/"

    cond do
      console?(route, pattern) -> :console
      shared?(pattern) -> :shared
      true -> :delivery
    end
  end

  defp console?(route, pattern) do
    live_session(route) in @console_live_sessions or
      :browser_dev_tools in List.wrap(Map.get(route, :pipe_through, [])) or
      under?(pattern, "/editor") or pattern == "/media"
  end

  defp shared?(pattern) do
    pattern in @shared_exact or Enum.any?(@shared_prefixes, &under?(pattern, &1))
  end

  # Segment-bounded: `/editor` and `/editor/x` are under `/editor`; `/editorial` is not.
  defp under?(pattern, prefix),
    do: pattern == prefix or String.starts_with?(pattern, prefix <> "/")

  @doc "Every router route with its surface, for the drift test and for docs."
  @spec all() :: [{surface(), String.t()}]
  def all do
    KilnCMSWeb.Router.__routes__()
    |> Enum.map(&{of(&1), &1.path})
    |> Enum.uniq()
    |> Enum.sort()
  end

  # The `live_session` name rides in the route's LiveView metadata; a plain
  # controller route has none.
  defp live_session(route) do
    case Map.get(route, :phoenix_live_view) || get_in(route, [:metadata, :phoenix_live_view]) do
      {_view, _action, _opts, %{name: name}} -> name
      _ -> nil
    end
  end
end
