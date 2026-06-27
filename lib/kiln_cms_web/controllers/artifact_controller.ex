defmodule KilnCMSWeb.ArtifactController do
  @moduledoc """
  Headless delivery of **fired artifacts** (Kiln v2 — decision D9).

  `GET /api/content/:type/:slug?surface=json` serves the immutable, pre-serialized
  output a published document compiled to on publish — read from the artifact
  cache/table via `KilnCMS.Firing.Engine.read/3`, **never** the live block tree.
  This is the v2 headless surface (the raw editable block tree is no longer auto-
  exposed). Surfaces: `json` (default, structured intent), `json_ld` (schema.org
  graph), `web` (`%{"html" => …}`).

  A published document with no stored artifact yet (the brief window after an
  async publish — perf #201 — or content published before firing shipped) is
  **not** compiled on the request path. Instead the endpoint enqueues a
  background firing job and answers `503` with `Retry-After`, so a 3-surface
  render can't block (or be used to flood) the API hot path (perf #208).
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Firing.Engine

  @surfaces %{"json" => :json, "json_ld" => :json_ld, "web" => :web}
  # How long clients should wait before retrying a still-compiling artifact.
  @retry_after_seconds 2
  # Artifacts are immutable per publish (republish updates `updated_at` and
  # evicts the firing cache), so they're cacheable; the ETag lets a CDN/static
  # build revalidate cheaply after the window (#188).
  @max_age_seconds 300

  def show(conn, %{"type" => type, "slug" => slug} = params) do
    locale = params["locale"] || KilnCMS.I18n.default_locale()

    with ct when not is_nil(ct) <- ContentTypes.get(type),
         surface when not is_nil(surface) <- Map.get(@surfaces, params["surface"] || "json"),
         record when not is_nil(record) <- published(ct.type, slug, locale),
         {:ok, body} <- artifact(ct.type, record, surface) do
      serve(conn, record, params["surface"] || "json", body)
    else
      :backfilling -> backfilling(conn)
      _ -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  # Serve a fired artifact with CDN/static-build cache headers (#188). Honour a
  # matching `If-None-Match` with a 304 so revalidation skips the body.
  defp serve(conn, record, surface, body) do
    etag = etag(record, surface)

    conn =
      conn
      |> put_resp_header("cache-control", "public, max-age=#{@max_age_seconds}")
      |> put_resp_header("etag", etag)
      |> put_resp_header("last-modified", http_date(record.updated_at))

    if etag in get_req_header(conn, "if-none-match") do
      send_resp(conn, :not_modified, "")
    else
      json(conn, body)
    end
  end

  # Strong ETag keyed on the record + surface + last-modified time, so it changes
  # whenever the document is republished.
  defp etag(record, surface) do
    ~s("#{record.id}-#{surface}-#{DateTime.to_unix(record.updated_at)}")
  end

  defp http_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S GMT")
  end

  defp published(type, slug, locale) do
    ContentTypes.get_published_by_slug(type, slug, locale, authorize?: false)
  rescue
    _ -> nil
  end

  # Serve the fired artifact. On a miss, enqueue a background firing job (deduped
  # by FireWorker's uniqueness) and signal `:backfilling` rather than compiling
  # 3 surfaces synchronously on this request.
  defp artifact(type, record, surface) do
    case Engine.read(type, record.id, surface) do
      {:ok, body} ->
        {:ok, body}

      :error ->
        enqueue_backfill(type, record.id)
        :backfilling
    end
  end

  defp enqueue_backfill(type, id) do
    %{"type" => to_string(type), "id" => id}
    |> KilnCMS.Firing.FireWorker.new()
    |> Oban.insert()
  end

  defp backfilling(conn) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(@retry_after_seconds))
    |> put_status(:service_unavailable)
    |> json(%{error: "artifact_compiling"})
  end
end
