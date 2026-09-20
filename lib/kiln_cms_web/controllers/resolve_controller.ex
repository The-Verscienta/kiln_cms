defmodule KilnCMSWeb.ResolveController do
  @moduledoc """
  Path resolution for headless front ends — one call answers "what lives at
  this URL?" including pathauto redirects, so a catch-all route can render or
  301 without mirroring Kiln's URL scheme or redirect table:

      GET /api/resolve?path=/blog/old-slug&locale=en

      {"status": "ok", "type": "post", "slug": "...", "id": "...", "path": "/blog/...", "locale": "en"}
      {"status": "moved", "to": "/blog/new-slug", "type": "post", "slug": "...", "id": "..."}
      404 {"status": "not_found"}

  ## Locale

  Content and path aliases resolve through the site's fallback chain
  (`KilnCMS.I18n.Fallback`) exactly as `GET /api/content/...` does, and take
  the same `?fallback=false` / `?fallback_locale=`. A resolved document says
  which locale it was found in — `locale` in the body, `x-kiln-locale` and
  `Content-Language` on the response — so a front end asked for `fr-CA` knows
  it is rendering the French page. The redirect table is **not** walked along
  the chain: a redirect is an editor's routing decision for one locale's URL,
  not a translation of it. An unsupported locale is `400 unsupported_locale`.

  Mirrors delivery semantics exactly: only published content resolves, content
  always beats a stale redirect, and redirects point at the record's *current*
  URL (no chains).

  ## `status` here is a verdict, not `KilnCMSWeb.ApiError`'s status code (#750)

  `"ok"` / `"moved"` / `"not_found"` is a three-valued answer to "what is at
  this path", not an HTTP status that happens to be spelled oddly — the 404
  above is a **response**, not an **error**: the path resolved cleanly to
  "nothing here", the same way a 200 resolves to "here it is". Kept as-is
  (not renamed to avoid colliding with the envelope's numeric `status`)
  because every one of these three answers already shares the same key, and
  splitting only the 404 case out would make the *consistent* member of the
  trio the odd one.

  A missing/malformed `?path=` **is** an error (there is no path to answer a
  verdict about), and answers `KilnCMSWeb.ApiError`'s envelope like every
  other headless surface.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Redirects
  alias KilnCMS.I18n.Fallback
  alias KilnCMSWeb.DeliveryLocale

  def show(conn, %{"path" => "/" <> _ = path} = params) do
    # Validated by `DeliveryLocale`, the same reading `/api/content/...` makes:
    # an unknown locale is a 400 on both rather than English here and a 404
    # there — two readings of the same question, which is the drift #751 is
    # about.
    case DeliveryLocale.parse(params) do
      {:ok, request} -> resolve(conn, path, request)
      error -> DeliveryLocale.send_error(conn, error)
    end
  end

  def show(conn, _params) do
    KilnCMSWeb.ApiError.send(
      conn,
      :bad_request,
      "missing_path",
      "pass ?path=/... (leading slash required)"
    )
  end

  defp resolve(conn, path, %{locale: locale, mode: mode}) do
    org_id = KilnCMSWeb.Tenant.current_org_id(conn)

    case lookup_content(path, locale, mode, org_id) do
      # A record found at its flat URL that carries a path alias (#485) is
      # canonically elsewhere — mirror delivery's 301.
      {ct, %{path_alias: alias_path} = record} when is_binary(alias_path) and alias_path != path ->
        moved(conn, alias_path, ct, record.slug, record.id)

      {ct, record} ->
        found(conn, path, ct, record)

      nil ->
        resolve_alias_or_redirect(conn, path, locale, mode, org_id)
    end
  end

  defp found(conn, path, ct, record) do
    conn
    |> put_resp_header("cache-control", "public, max-age=60")
    |> DeliveryLocale.put_served(record.locale)
    |> json(%{
      status: "ok",
      type: to_string(ct.type),
      slug: record.slug,
      id: record.id,
      path: path,
      locale: record.locale
    })
  end

  defp resolve_alias_or_redirect(conn, path, locale, mode, org_id) do
    alias_hit =
      org_id
      |> Fallback.chain(locale, mode)
      |> Enum.find_value(&KilnCMS.CMS.Slugs.find_published_by_alias(path, &1, org_id))

    case alias_hit do
      {ct, record} ->
        found(conn, path, ct, record)

      nil ->
        case Redirects.resolve(path, locale, org_id) do
          nil ->
            # Same posture as delivery 404s: don't let a cache mask the page
            # once it publishes.
            conn
            |> put_resp_header("cache-control", "no-store")
            |> put_status(:not_found)
            |> json(%{status: "not_found"})

          %{to: to, type: type, slug: slug, id: id} ->
            conn
            |> put_resp_header("cache-control", "public, max-age=60")
            |> json(%{status: "moved", to: to, type: type, slug: slug, id: id})
        end
    end
  end

  defp moved(conn, to, ct, slug, id) do
    conn
    |> put_resp_header("cache-control", "public, max-age=60")
    |> json(%{status: "moved", to: to, type: to_string(ct.type), slug: slug, id: id})
  end

  # The delivery URL scheme: one segment is a root-served page, two segments
  # are `/<type prefix>/<slug>`. Anything deeper doesn't exist.
  defp lookup_content(path, locale, mode, org_id) do
    case String.split(path, "/", trim: true) do
      [slug] ->
        fetch_published(ContentTypes.get(:page), slug, locale, mode, org_id)

      [segment, slug] ->
        fetch_published(ContentTypes.get_by_path(segment, org_id), slug, locale, mode, org_id)

      _ ->
        nil
    end
  end

  defp fetch_published(nil, _slug, _locale, _mode, _org_id), do: nil

  # Delivery bypass (see `KilnCMSWeb.ContentController`'s moduledoc): the
  # anonymous resolver has no actor; the `:public_by_slug` action's own filter
  # limits the read to published, public, unlocked records and `tenant:` pins
  # it to this site. Only the type/slug/id of a hit leave the endpoint.
  defp fetch_published(ct, slug, locale, mode, org_id) do
    case ContentTypes.get_published_by_slug(ct.type, slug, locale,
           fallback: mode,
           not_found_error?: false,
           authorize?: false,
           tenant: org_id
         ) do
      nil -> nil
      record -> {ct, record}
    end
  end
end
