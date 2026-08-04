defmodule KilnCMSWeb.ArtifactController do
  @moduledoc """
  Headless delivery of **fired artifacts** (Kiln v2 — decision D9).

  `GET /api/content/:type/:slug?surface=json` serves the immutable, pre-serialized
  output a published document compiled to on publish — read from the artifact
  cache/table via `KilnCMS.Firing.Engine.read/4`, **never** the live block tree.
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
  alias KilnCMS.Firing.Delivery
  alias KilnCMS.Firing.Engine
  alias KilnCMS.Firing.PointInTime
  alias KilnCMSWeb.ApiError
  alias KilnCMSWeb.Params
  alias KilnCMSWeb.ViewTracking

  @surfaces KilnCMS.Firing.Surfaces.name_map()
  # How long clients should wait before retrying a still-compiling artifact.
  @retry_after_seconds 2
  # Artifacts are immutable per publish (republish updates `updated_at` and
  # evicts the firing cache), so they're cacheable; the ETag lets a CDN/static
  # build revalidate cheaply after the window (#188).
  @max_age_seconds 300

  def show(conn, %{"as_of" => _} = params), do: show_point_in_time(conn, params)

  def show(conn, %{"type" => type, "slug" => slug} = params) do
    locale = Params.string(params, "locale", KilnCMS.I18n.default_locale())
    # The request's tenant, resolved from the host by KilnCMSWeb.Plugs.SetTenant
    # (epic #336). Delivery is scoped to this org so one site's slug never serves
    # another's content.
    org_id = current_org_id(conn)

    # Resolution and body reads go through KilnCMS.Firing.Delivery, which is
    # cache-first and DB-error-tolerant: a warm request touches no database at
    # all, so delivery keeps answering through a Postgres outage (#341).
    with ct when not is_nil(ct) <- ContentTypes.get(type),
         surface when not is_nil(surface) <- Map.get(@surfaces, params["surface"] || "json"),
         {:ok, record} <- Delivery.published(org_id, ct.type, slug, locale),
         {:ok, body} <- artifact(record, surface) do
      surface_name = params["surface"] || "json"

      # Count the fetch, so a headless front end's traffic reaches
      # `/editor/analytics` instead of reading as zero (the visitor's browser
      # never touches Kiln, so this request is the only delivery event there
      # is). Tracked here rather than inside `serve/4` for two reasons: the
      # public type name is `ct.type`, which `serve/4` doesn't carry (a dynamic
      # type's *storage* type is the shared `:entry` tier, so deriving it from
      # the record would file every dynamic document under one name), and a
      # revalidating client that gets the 304 below is still actively serving
      # this document — excluding it would make a CDN-fronted site report
      # near-zero, which is the gap this closes. Only live delivery counts:
      # `?as_of=` snapshots (compliance reads) and the draft visual-editing
      # surface deliberately do not.
      ViewTracking.track(surface_name, to_string(ct.type), record.id, record.org_id)

      serve(conn, record, surface_name, body)
    else
      :backfilling -> backfilling(conn)
      :unavailable -> unavailable(conn)
      _ -> ApiError.send(conn, :not_found, "not_found", "Content not found.")
    end
  end

  # Point-in-time delivery (#338): `?as_of=<ISO8601 date or datetime>` serves the
  # artifact for this content *as it was published on that date*, reconstructed
  # from PaperTrail history and re-fired in memory (KilnCMS.Firing.PointInTime).
  @doc """
  `GET /api/content/:type?as_of=` — the **collection as of a date** (#338
  phase 2): index entries for every document of `type` that was published at
  that instant (title/slug reconstructed from history), each linking its
  point-in-time artifact. `as_of` is required — the live collection view is
  the JSON:API / GraphQL surface's job.
  """
  def index_point_in_time(conn, %{"type" => type, "as_of" => raw} = params) do
    org_id = current_org_id(conn)

    with {:ok, as_of} <- parse_as_of(raw),
         ct when not is_nil(ct) <- ContentTypes.get(type, org_id),
         {resource, definition_id} when not is_nil(resource) <- storage(ct) do
      limit = index_limit(params)

      entries =
        KilnCMS.Cache.fetch(
          {:pit_index, org_id, type, DateTime.to_iso8601(as_of), limit},
          :timer.minutes(5),
          fn ->
            PointInTime.index(org_id, resource, as_of,
              limit: limit,
              type_definition_id: definition_id
            )
          end
        )

      entries =
        Enum.map(entries, fn entry ->
          %{
            slug: entry.slug,
            title: entry.title,
            published_at: entry.published_at,
            # The per-document snapshot endpoint resolves by CURRENT slug and
            # published state — a since-unpublished or since-renamed document
            # has no working snapshot URL (id-addressable history is the
            # documented later phase), so emit an honest null over a dead link.
            href: snapshot_href(org_id, ct.type, type, entry.slug, as_of)
          }
        end)

      conn
      |> put_resp_header("cache-control", "public, max-age=#{@max_age_seconds}")
      |> put_resp_header("x-kiln-as-of", DateTime.to_iso8601(as_of))
      |> json(%{as_of: as_of, type: type, entries: entries})
    else
      :error ->
        ApiError.send(
          conn,
          :bad_request,
          "invalid_as_of",
          "`as_of` must be an ISO 8601 date or datetime."
        )

      _ ->
        ApiError.send(conn, :not_found, "not_found", "Unknown content type.")
    end
  end

  def index_point_in_time(conn, _params) do
    ApiError.send(
      conn,
      :bad_request,
      "missing_as_of",
      "This collection view is historical: pass `as_of` (the live collection is served by the JSON:API/GraphQL surfaces)."
    )
  end

  # Where a content type's history actually lives (D17): a compiled type owns
  # its own table, every dynamic type shares `KilnCMS.CMS.Entry`. The
  # definition id comes back with it because that shared table needs scoping —
  # without it, one dynamic type's historical index would list every other
  # type's documents.
  defp storage(%{source: :dynamic, definition: %{id: id}}), do: {KilnCMS.CMS.Entry, id}
  defp storage(%{resource: resource}), do: {resource, nil}

  defp snapshot_href(org_id, storage_type, public_type, slug, as_of) do
    locale = KilnCMS.I18n.default_locale()

    case Delivery.published(org_id, storage_type, slug, locale) do
      {:ok, _record} ->
        "/api/content/#{public_type}/#{slug}?as_of=#{DateTime.to_iso8601(as_of)}"

      _ ->
        nil
    end
  end

  # Bounded page size for the historical index.
  defp index_limit(params), do: Params.integer(params, "limit", 100, 1..500)

  # The content must still be resolvable now (lookup is by the current record's
  # id); see the module for scope.
  defp show_point_in_time(conn, %{"type" => type, "slug" => slug} = params) do
    locale = Params.string(params, "locale", KilnCMS.I18n.default_locale())
    org_id = current_org_id(conn)

    # The storage resource comes from the resolved RECORD, not the registry
    # descriptor: a dynamic type's descriptor carries `resource: nil` because
    # its documents live on the shared entry tier (D17), and the record already
    # knows which table it came from.
    with {:ok, as_of} <- parse_as_of(params["as_of"]),
         ct when not is_nil(ct) <- ContentTypes.get(type, org_id),
         surface when not is_nil(surface) <- Map.get(@surfaces, params["surface"] || "json"),
         record when not is_nil(record) <- published(org_id, ct.type, slug, locale),
         {:ok, body, published_at} <-
           PointInTime.read(org_id, record.__struct__, record.id, surface, as_of) do
      serve_point_in_time(conn, as_of, published_at, params["surface"] || "json", body)
    else
      :error ->
        ApiError.send(
          conn,
          :bad_request,
          "invalid_as_of",
          "`as_of` must be an ISO 8601 date or datetime."
        )

      {:error, :not_published} ->
        ApiError.send(conn, :not_found, "not_published", "No published version as of that date.")

      # Distinct from never-published: this content existed and had been taken
      # down at that moment. A compliance reader asking "what did this say on
      # date X" is owed "it wasn't published then", not the prior publish.
      {:error, :withdrawn} ->
        ApiError.send(
          conn,
          :not_found,
          "withdrawn",
          "This content had been withdrawn as of that date."
        )

      _ ->
        ApiError.send(conn, :not_found, "not_found", "Content not found.")
    end
  end

  # A client picks the *shape* of a query param, not just its value: `?as_of[]=`
  # arrives as a list and `?as_of[a]=` as a map, neither of which
  # `DateTime.from_iso8601/1` has a clause for. Refused as invalid rather than
  # read as absent (`KilnCMSWeb.Params`), because absent here means "serve the
  # live document" — the wrong answer to a compliance reader asking what this
  # said on a date.
  defp parse_as_of(raw) when not is_binary(raw), do: :error

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
  defp serve_point_in_time(conn, as_of, published_at, surface, body) do
    conn
    |> put_resp_header("cache-control", "public, max-age=#{@max_age_seconds}")
    |> put_resp_header("x-kiln-as-of", DateTime.to_iso8601(as_of))
    |> put_resp_header("x-kiln-published-at", DateTime.to_iso8601(published_at))
    # Same per-surface envelope as live delivery — :llm is raw text/markdown
    # with or without as_of.
    |> respond(surface, body)
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
      |> maybe_provenance_header(record, surface)

    if etag in get_req_header(conn, "if-none-match") do
      send_resp(conn, :not_modified, "")
    else
      respond(conn, surface, body)
    end
  end

  # The :llm surface is raw Markdown (#357) — LLM crawlers fetch it directly,
  # so no JSON envelope; every other surface keeps the JSON body.
  defp respond(conn, "llm", %{"markdown" => markdown}) do
    conn
    |> put_resp_content_type("text/markdown")
    |> send_resp(200, markdown)
  end

  defp respond(conn, _surface, body), do: json(conn, body)

  # Advertise the signed provenance manifest for this artifact (#340) when
  # provenance is enabled, so consumers can discover the verification surface
  # from the delivery response. A no-op (cheap config read) when disabled.
  defp maybe_provenance_header(conn, record, surface) do
    if KilnCMS.Provenance.enabled?() do
      url = "/api/provenance/#{Engine.public_type(record)}/#{record.slug}?surface=#{surface}"
      put_resp_header(conn, "x-kiln-provenance", url)
    else
      conn
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

  defp published(org_id, type, slug, locale) do
    ContentTypes.get_published_by_slug(type, slug, locale, authorize?: false, tenant: org_id)
  rescue
    _ -> nil
  end

  defp current_org_id(conn), do: KilnCMSWeb.Tenant.current_org_id(conn)

  # Serve the fired artifact. On a miss, enqueue a background firing job (deduped
  # by FireWorker's uniqueness) and signal `:backfilling` rather than compiling
  # 3 surfaces synchronously on this request.
  # Artifacts are stored under the record's *storage* type — for dynamic types
  # that's the generic `:entry` tier (D17), not the requested type name, so the
  # key comes from the record struct rather than the registry descriptor.
  defp artifact(record, surface) do
    type = Engine.document_type(record)

    # `record.org_id` == the request tenant (the record was resolved through the
    # tenant-scoped `Delivery.published/4`), so the artifact read + backfill stay
    # in the same org.
    case Delivery.read_artifact(record.org_id, type, record.id, surface) do
      {:ok, body} ->
        {:ok, body}

      :unavailable ->
        :unavailable

      :miss ->
        enqueue_backfill(record.org_id, type, record.id)
        :backfilling
    end
  end

  defp enqueue_backfill(org_id, type, id) do
    %{"org_id" => org_id, "type" => to_string(type), "id" => id}
    |> KilnCMS.Firing.FireWorker.new()
    |> Oban.insert()
  end

  defp backfilling(conn) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(@retry_after_seconds))
    |> ApiError.send(
      :service_unavailable,
      "artifact_compiling",
      "Artifact is compiling; retry shortly."
    )
  end

  # The database is down and this content isn't warm in cache (#341). Warm
  # content is served above without ever reaching here. Signal a retryable 503 —
  # no Oban enqueue (that would need the DB too).
  defp unavailable(conn) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(@retry_after_seconds))
    |> ApiError.send(
      :service_unavailable,
      "temporarily_unavailable",
      "Content is temporarily unavailable; retry shortly."
    )
  end
end
