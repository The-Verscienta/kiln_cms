defmodule KilnCMSWeb.MenuController do
  @moduledoc """
  Navigation delivery for headless consumers (#466).

      GET /api/menus                 → every menu's key/name/locale
      GET /api/menus/:key            → one resolved menu tree (request locale)
      GET /api/menus/:key?locale=fr  → the French variant

  A missing locale variant follows the site's *configured* fallback chain
  only (`KilnCMS.CMS.Menus.resolve/4`), plus `?fallback=false` and
  `?fallback_locale=` as on every delivery surface. The body's `locale` and the
  `x-kiln-locale` / `Content-Language` headers name the variant served. A
  locale the site does not run is `400 unsupported_locale`.

  A resolved item carries a **live** `url`: a `content` item's destination is
  computed from the target's current published path, so renaming a slug moves
  the nav with it. Items whose target isn't published — and items an editor has
  switched off — are omitted along with their children, so an anonymous
  consumer never renders a link into a 404.

  Deliberately a hand-written controller rather than a raw JSON:API resource
  read: the resource read returns *stored* rows, which carry references and no
  URLs, and applying the visibility rules is the entire value of this endpoint.
  The auto JSON:API/GraphQL surfaces on `Menu`/`MenuItem` remain for consumers
  that want the raw structure.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Menus
  alias KilnCMS.I18n
  alias KilnCMSWeb.DeliveryLocale

  # Navigation changes rarely and is fetched on every page of a front end, so
  # let shared caches hold it briefly — same posture as the artifact endpoint.
  # No `Vary` is needed: the locale is part of the URL (`?locale=` or the
  # `/fr/…` prefix), never a header or a cookie, so the URL is the whole key.
  @max_age_seconds 60

  def index(conn, _params) do
    # `authorize?: false`: a headless consumer has no actor, and `Menu`'s read
    # policy is `authorize_if always()` regardless; `tenant:` scopes the list to
    # this site and only key/name/locale leave the controller.
    menus =
      CMS.list_menus!(authorize?: false, tenant: KilnCMSWeb.Tenant.current_org_id(conn))

    conn
    |> cache_headers()
    |> json(%{
      menus: Enum.map(menus, &%{key: &1.key, name: &1.name, locale: &1.locale})
    })
  end

  def show(conn, %{"key" => key} = params) do
    case conn |> requested_locale(params) |> DeliveryLocale.parse() do
      {:ok, request} -> show_menu(conn, key, request)
      error -> DeliveryLocale.send_error(conn, error)
    end
  end

  defp show_menu(conn, key, %{locale: locale, mode: mode}) do
    org_id = KilnCMSWeb.Tenant.current_org_id(conn)

    case Menus.resolve(key, locale, org_id, fallback: mode) do
      {:ok, menu, tree} ->
        conn
        |> cache_headers()
        |> DeliveryLocale.put_served(menu.locale)
        |> json(%{key: menu.key, name: menu.name, locale: menu.locale, items: tree})

      :not_found ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "no menu \"#{key}\" for locale \"#{locale}\""})
    end
  end

  # An explicit `?locale=` wins; otherwise the **default** locale. Deliberately
  # not `conn.assigns[:locale]`: `Plugs.SetLocale` derives that from the session
  # cookie when there's no path prefix, and this response is `public`-cacheable,
  # so a shared cache would store the French tree built for a signed-in editor
  # and serve it to every anonymous visitor. The path-prefix form
  # (`/fr/api/menus/main`) is already a distinct cache key and still works,
  # because `SetLocale` rewrites `path_info` before the router.
  #
  # Returns the params with the locale to start from filled in, for
  # `DeliveryLocale.parse/1` to validate — which refuses a locale the site does
  # not run (`400 unsupported_locale`) rather than silently answering with the
  # default menu, as this endpoint used to: a typo and a missing translation
  # looked identical to the front end.
  defp requested_locale(conn, params) do
    if Map.has_key?(params, "locale"),
      do: params,
      else: Map.put(params, "locale", conn.assigns[:path_locale] || I18n.default_locale())
  end

  defp cache_headers(conn) do
    put_resp_header(conn, "cache-control", "public, max-age=#{@max_age_seconds}")
  end
end
