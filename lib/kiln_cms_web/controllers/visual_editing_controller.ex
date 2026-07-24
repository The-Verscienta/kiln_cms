defmodule KilnCMSWeb.VisualEditingController do
  @moduledoc """
  Annotated preview read for the visual-editing bridge (#355).

  `GET /api/visual-editing/:type/:slug` returns the **live working copy** of a
  document (draft or published — whatever the caller's actor may read) rendered
  to the `:json` surface and **stega-annotated** so the bridge overlay can map a
  rendered value back to its Kiln field. Unlike the public fired-artifact route
  (`/api/content/...`), this renders live (never a stored artifact) and is
  per-actor, so it is `no-store` and gated by the caller's identity:

    * an editor/admin **API key** (`Authorization: Bearer kiln_…`) sees the
      working draft — the normal case (the editor previews their own external
      front end in edit mode);
    * an anonymous caller sees only published content (the read policy), so the
      route can't leak drafts.

  Cross-origin access is governed by `KilnCMSWeb.Plugs.ApiCORS` (the `/api`
  surface) exactly like the write API the bridge rounds-trips to. The whole
  surface can be turned off with `VISUAL_EDITING_ENABLED=false`.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Firing.Engine
  alias KilnCMS.VisualEditing

  def show(conn, %{"type" => type, "slug" => slug} = params) do
    locale = params["locale"] || KilnCMS.I18n.default_locale()
    actor = Ash.PlugHelpers.get_actor(conn)

    with true <- VisualEditing.enabled?(),
         ct when not is_nil(ct) <- ContentTypes.get(type),
         record when not is_nil(record) <-
           fetch_by_slug(ct.type, slug, locale, actor, KilnCMSWeb.Tenant.current_org_id(conn)),
         {:ok, %{json: json}} <- Engine.fire(record, mode: :preview) do
      # The public `:json` artifact deliberately omits custom fields; the
      # annotated preview mirrors what a custom-fields-driven front end
      # renders, so it carries the working copy's map (stega-annotated below).
      json = Map.put(json, "custom_fields", record.custom_fields || %{})

      conn
      # Per-actor draft content: never cache in a shared cache.
      |> put_resp_header("cache-control", "no-store")
      |> json(VisualEditing.annotate(json))
    else
      false -> not_found(conn, "Visual editing is disabled.")
      _ -> not_found(conn, "Content not found.")
    end
  end

  # Load the live working copy by slug+locale, scoped by the actor's read policy
  # (editors/admins see drafts; anonymous sees published only) and by the request
  # host's org (epic #336). Mirrors `KilnCMSWeb.InContextEditLive.fetch_by_slug/4`,
  # scoped to a locale.
  defp fetch_by_slug(kind, slug, locale, actor, org_id) do
    case ContentTypes.list!(kind,
           actor: actor,
           tenant: org_id,
           query: [filter: [slug: slug, locale: locale], select: [:id], limit: 1]
         ) do
      [%{id: id} | _] ->
        ContentTypes.get_record!(kind, id, actor: actor, tenant: org_id, load: [:featured_image])

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp not_found(conn, message) do
    conn
    |> put_status(:not_found)
    |> json(%{"errors" => [%{"detail" => message}]})
  end
end
