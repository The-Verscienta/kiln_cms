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
  alias KilnCMS.Firing.Delivery
  alias KilnCMS.Search.Related
  alias KilnCMSWeb.ApiError
  alias KilnCMSWeb.Params

  @max_age_seconds 300

  def show(conn, %{"type" => type, "slug" => slug} = params) do
    org_id = KilnCMSWeb.Tenant.current_org_id(conn)
    locale = Params.string(params, "locale", KilnCMS.I18n.default_locale())

    with ct when not is_nil(ct) <- ContentTypes.get(type),
         {:ok, record} <- Delivery.published(org_id, ct.type, slug, locale) do
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
      # Cache-first, DB-outage-aware resolution (same posture as delivery):
      # a database outage answers 503-retryable, never a cacheable 404.
      :unavailable ->
        conn
        |> put_resp_header("retry-after", "2")
        |> ApiError.send(
          :service_unavailable,
          "temporarily_unavailable",
          "Content is temporarily unavailable; retry shortly."
        )

      _ ->
        ApiError.send(conn, :not_found, "not_found", "Content not found.")
    end
  end

  defp limit(params), do: Params.integer(params, "limit", 5, 1..20)
end
