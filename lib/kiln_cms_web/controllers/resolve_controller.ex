defmodule KilnCMSWeb.ResolveController do
  @moduledoc """
  Path resolution for headless front ends — one call answers "what lives at
  this URL?" including pathauto redirects, so a catch-all route can render or
  301 without mirroring Kiln's URL scheme or redirect table:

      GET /api/resolve?path=/blog/old-slug&locale=en

      {"status": "ok", "type": "post", "slug": "...", "id": "...", "path": "/blog/..."}
      {"status": "moved", "to": "/blog/new-slug", "type": "post", "slug": "...", "id": "..."}
      404 {"status": "not_found"}

  Mirrors delivery semantics exactly: only published content resolves, content
  always beats a stale redirect, and redirects point at the record's *current*
  URL (no chains).
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Redirects
  alias KilnCMS.I18n

  def show(conn, %{"path" => "/" <> _ = path} = params) do
    locale = params["locale"] || I18n.default_locale()
    org_id = KilnCMSWeb.Tenant.current_org_id(conn)

    case lookup_content(path, locale, org_id) do
      # A record found at its flat URL that carries a path alias (#485) is
      # canonically elsewhere — mirror delivery's 301.
      {ct, %{path_alias: alias_path} = record} when is_binary(alias_path) and alias_path != path ->
        moved(conn, alias_path, ct, record.slug, record.id)

      {ct, record} ->
        conn
        |> put_resp_header("cache-control", "public, max-age=60")
        |> json(%{
          status: "ok",
          type: to_string(ct.type),
          slug: record.slug,
          id: record.id,
          path: path
        })

      nil ->
        resolve_alias_or_redirect(conn, path, locale, org_id)
    end
  end

  def show(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "pass ?path=/... (leading slash required)"})
  end

  defp resolve_alias_or_redirect(conn, path, locale, org_id) do
    case KilnCMS.CMS.Slugs.find_published_by_alias(path, locale, org_id) do
      {ct, record} ->
        conn
        |> put_resp_header("cache-control", "public, max-age=60")
        |> json(%{
          status: "ok",
          type: to_string(ct.type),
          slug: record.slug,
          id: record.id,
          path: path
        })

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
  defp lookup_content(path, locale, org_id) do
    case String.split(path, "/", trim: true) do
      [slug] ->
        fetch_published(ContentTypes.get(:page), slug, locale, org_id)

      [segment, slug] ->
        fetch_published(ContentTypes.get_by_path(segment, org_id), slug, locale, org_id)

      _ ->
        nil
    end
  end

  defp fetch_published(nil, _slug, _locale, _org_id), do: nil

  defp fetch_published(ct, slug, locale, org_id) do
    case ContentTypes.get_published_by_slug(ct.type, slug, locale,
           not_found_error?: false,
           authorize?: false,
           tenant: org_id
         ) do
      nil -> nil
      record -> {ct, record}
    end
  end
end
