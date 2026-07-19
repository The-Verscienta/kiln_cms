defmodule KilnCMSWeb.RelatedController do
  @moduledoc """
  `GET /api/content/:type/:slug/related` (#339 phase 2) — published documents
  semantically closest to this one, from the block embeddings that already
  index the site. Public and published-only on both ends (the anchor document
  must be published; results are filtered to published), org-scoped like the
  rest of delivery. An empty list when semantic search is disabled.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Search.Related

  @max_age_seconds 300

  def show(conn, %{"type" => type, "slug" => slug} = params) do
    org_id = KilnCMSWeb.Tenant.current_org_id(conn)
    locale = params["locale"] || KilnCMS.I18n.default_locale()

    with ct when not is_nil(ct) <- ContentTypes.get(type),
         record when not is_nil(record) <- published(org_id, type, slug, locale) do
      related =
        record
        |> Related.related_documents(limit: limit(params))
        |> Enum.map(fn n ->
          %{
            type: n.type,
            slug: n.slug,
            title: n.title,
            score: Float.round(1.0 - n.distance, 4),
            href: "/api/content/#{n.type}/#{n.slug}"
          }
        end)

      conn
      |> put_resp_header("cache-control", "public, max-age=#{@max_age_seconds}")
      |> json(%{type: type, slug: slug, related: related})
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: [%{status: "404", code: "not_found", detail: "Content not found."}]})
    end
  end

  defp limit(params) do
    case Integer.parse(params["limit"] || "") do
      {n, ""} when n in 1..20 -> n
      _ -> 5
    end
  end

  # Same published-only, org-scoped lookup as artifact delivery.
  defp published(org_id, type, slug, locale) do
    ContentTypes.get_published_by_slug(type, slug, locale, authorize?: false, tenant: org_id)
  rescue
    _ -> nil
  end
end
