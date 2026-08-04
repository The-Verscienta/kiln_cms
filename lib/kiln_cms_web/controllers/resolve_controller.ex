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
  alias KilnCMS.I18n
  alias KilnCMSWeb.Params

  def show(conn, %{"path" => "/" <> _ = path} = params) do
    # Shape-checked only. `I18n.normalize/1` is right there and does validate,
    # but substituting the default for an unknown locale would answer 200 with
    # the English document where `/api/content/...?locale=de` answers 404 — two
    # readings of the same question, which is the drift #751 is about.
    locale = Params.string(params, "locale", I18n.default_locale())
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
    KilnCMSWeb.ApiError.send(
      conn,
      :bad_request,
      "missing_path",
      "pass ?path=/... (leading slash required)"
    )
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
