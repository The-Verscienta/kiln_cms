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
  alias KilnCMS.Firing.PointInTime

  @surfaces %{"json" => :json, "json_ld" => :json_ld, "web" => :web}
  # How long clients should wait before retrying a still-compiling artifact.
  @retry_after_seconds 2
  # Artifacts are immutable per publish (republish updates `updated_at` and
  # evicts the firing cache), so they're cacheable; the ETag lets a CDN/static
  # build revalidate cheaply after the window (#188).
  @max_age_seconds 300

  def show(conn, %{"as_of" => _} = params), do: show_point_in_time(conn, params)

  def show(conn, %{"type" => type, "slug" => slug} = params) do
    locale = params["locale"] || KilnCMS.I18n.default_locale()

    with ct when not is_nil(ct) <- ContentTypes.get(type),
         surface when not is_nil(surface) <- Map.get(@surfaces, params["surface"] || "json"),
         record when not is_nil(record) <- published(ct.type, slug, locale),
         {:ok, body} <- artifact(record, surface) do
      serve(conn, record, params["surface"] || "json", body)
    else
      :backfilling -> backfilling(conn)
      _ -> error(conn, :not_found, "not_found", "Content not found.")
    end
  end

  # Point-in-time delivery (#338): `?as_of=<ISO8601 date or datetime>` serves the
  # artifact for this content *as it was published on that date*, reconstructed
  # from PaperTrail history and re-fired in memory (KilnCMS.Firing.PointInTime).
  # The content must still be resolvable now (lookup is by the current record's
  # id); see the module for scope.
  defp show_point_in_time(conn, %{"type" => type, "slug" => slug} = params) do
    locale = params["locale"] || KilnCMS.I18n.default_locale()

    with {:ok, as_of} <- parse_as_of(params["as_of"]),
         ct when not is_nil(ct) <- ContentTypes.get(type),
         surface when not is_nil(surface) <- Map.get(@surfaces, params["surface"] || "json"),
         record when not is_nil(record) <- published(ct.type, slug, locale),
         {:ok, body, published_at} <- PointInTime.read(ct.resource, record.id, surface, as_of) do
      serve_point_in_time(conn, as_of, published_at, body)
    else
      :error ->
        error(
          conn,
          :bad_request,
          "invalid_as_of",
          "`as_of` must be an ISO 8601 date or datetime."
        )

      {:error, :not_published} ->
        error(conn, :not_found, "not_published", "No published version as of that date.")

      _ ->
        error(conn, :not_found, "not_found", "Content not found.")
    end
  end

  # Accept a full ISO 8601 datetime, or a bare date (treated as the end of that
  # day, UTC — "as of that day" captures the last publish during it).
  defp parse_as_of(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      _ ->
        case Date.from_iso8601(raw) do
          {:ok, date} -> {:ok, DateTime.new!(date, ~T[23:59:59.999999], "Etc/UTC")}
          _ -> :error
        end
    end
  end

  # Historical snapshots are immutable for a given (content, as_of), so they're
  # cacheable; the headers name the requested moment and the effective publish.
  defp serve_point_in_time(conn, as_of, published_at, body) do
    conn
    |> put_resp_header("cache-control", "public, max-age=#{@max_age_seconds}")
    |> put_resp_header("x-kiln-as-of", DateTime.to_iso8601(as_of))
    |> put_resp_header("x-kiln-published-at", DateTime.to_iso8601(published_at))
    |> json(body)
  end

  # Standard error envelope shared with the other headless surfaces (#190):
  # `{"errors": [{"status", "code", "detail"}]}`.
  defp error(conn, status, code, detail) do
    conn
    |> put_status(status)
    |> json(%{
      errors: [%{status: to_string(Plug.Conn.Status.code(status)), code: code, detail: detail}]
    })
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
  # Artifacts are stored under the record's *storage* type — for dynamic types
  # that's the generic `:entry` tier (D17), not the requested type name, so the
  # key comes from the record struct rather than the registry descriptor.
  defp artifact(record, surface) do
    type = Engine.document_type(record)

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
    |> error(:service_unavailable, "artifact_compiling", "Artifact is compiling; retry shortly.")
  end
end
