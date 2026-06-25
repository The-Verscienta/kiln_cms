defmodule KilnCMSWeb.ArtifactController do
  @moduledoc """
  Headless delivery of **fired artifacts** (Kiln v2 — decision D9).

  `GET /api/content/:type/:slug?surface=json` serves the immutable, pre-serialized
  output a published document compiled to on publish — read from the artifact
  cache/table via `KilnCMS.Firing.Engine.read/3`, **never** the live block tree.
  This is the v2 headless surface (the raw editable block tree is no longer auto-
  exposed). Surfaces: `json` (default, structured intent), `json_ld` (schema.org
  graph), `web` (`%{"html" => …}`).

  A published document with no stored artifact yet (e.g. published before firing
  shipped) is compiled on the fly via preview firing, so the endpoint always
  answers for published content.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Firing.Engine

  @surfaces %{"json" => :json, "json_ld" => :json_ld, "web" => :web}

  def show(conn, %{"type" => type, "slug" => slug} = params) do
    locale = params["locale"] || KilnCMS.I18n.default_locale()

    with ct when not is_nil(ct) <- ContentTypes.get(type),
         surface when not is_nil(surface) <- Map.get(@surfaces, params["surface"] || "json"),
         record when not is_nil(record) <- published(ct.type, slug, locale),
         {:ok, body} <- artifact(ct.type, record, surface) do
      json(conn, body)
    else
      _ -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  defp published(type, slug, locale) do
    ContentTypes.get_published_by_slug(type, slug, locale, authorize?: false)
  rescue
    _ -> nil
  end

  # Prefer the fired artifact; fall back to on-the-fly preview firing if a
  # published document has no artifact stored yet.
  defp artifact(type, record, surface) do
    case Engine.read(type, record.id, surface) do
      {:ok, body} ->
        {:ok, body}

      :error ->
        {:ok, artifacts} = Engine.fire(record, mode: :preview)
        {:ok, artifacts[surface]}
    end
  end
end
