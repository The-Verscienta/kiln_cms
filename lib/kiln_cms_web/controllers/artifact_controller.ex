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

  def show(conn, %{"type" => type, "slug" => slug} = params) do
    locale = params["locale"] || KilnCMS.I18n.default_locale()

    with ct when not is_nil(ct) <- ContentTypes.get(type),
         surface when not is_nil(surface) <- Map.get(@surfaces, params["surface"] || "json"),
         record when not is_nil(record) <- published(ct.type, slug, locale),
         {:ok, body} <- artifact(ct.type, record, surface) do
      json(conn, body)
    else
      :backfilling -> backfilling(conn)
      _ -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
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
