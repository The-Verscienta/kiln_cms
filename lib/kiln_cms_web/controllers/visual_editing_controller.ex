defmodule KilnCMSWeb.VisualEditingController do
  @moduledoc """
  Annotated preview read for the visual-editing bridge (#355).

  `GET /api/visual-editing/:type/:slug` returns the **live working copy** of a
  document (draft or published — whatever the caller's actor may read) rendered
  to the `:json` surface and **stega-annotated** so the bridge overlay can map a
  rendered value back to its Kiln field. Unlike the public fired-artifact route
  (`/api/content/...`), this renders live (never a stored artifact) and is
  per-caller, so it is `no-store` and gated by the caller's credential:

    * a **preview token** (`x-kiln-preview-token: <token>`, or
      `?preview_token=<token>` for a client that cannot set headers) sees the
      one draft it was minted for (`KilnCMS.CMS.PreviewToken`) — the
      recommended credential for a browser, since it is read-only,
      per-document and expires in 15 minutes. For a live document with
      unpublished edits it reads the **working copy**
      (`KilnCMS.CMS.WorkingCopy.view/1`), as `GET /preview/:token` does: the
      pending text is what a token is minted to show, and why only an editor
      with draft visibility may mint one;
    * an editor/admin **API key** (`Authorization: Bearer kiln_…`) sees the
      working draft of anything its owner can read;
    * an anonymous caller sees only published content (the read policy), so the
      route can't leak drafts.

  A presented token is the *only* credential consulted: one that does not
  verify, or names another document, another site, another slug or another
  locale, is answered `404 invalid_preview` rather than falling back to the
  bearer or to an anonymous read. A front end whose token lapsed then learns
  it has to re-mint, instead of quietly rendering the published page.

  Cross-origin access is governed by `KilnCMSWeb.Plugs.ApiCORS` (the `/api`
  surface) exactly like the write API the bridge rounds-trips to. The whole
  surface can be turned off with `VISUAL_EDITING_ENABLED=false`.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.PreviewToken
  alias KilnCMS.CMS.WorkingCopy
  alias KilnCMS.Firing.Engine
  alias KilnCMS.VisualEditing
  alias KilnCMSWeb.ApiError
  alias KilnCMSWeb.Params

  @token_header "x-kiln-preview-token"

  @doc "The request header `show/2` reads a preview token from."
  @spec token_header() :: String.t()
  def token_header, do: @token_header

  def show(conn, %{"type" => type, "slug" => slug} = params) do
    org_id = KilnCMSWeb.Tenant.current_org_id(conn)

    with true <- VisualEditing.enabled?(),
         ct when not is_nil(ct) <- ContentTypes.get(type, org_id),
         {:ok, record} <- fetch(conn, ct, slug, params, org_id),
         {:ok, %{json: json}} <- Engine.fire(record, mode: :preview) do
      # `custom_fields` now rides on the `:json` artifact itself (#428/#429), so
      # the fired map is used as-is. It is strictly fresher than the record's
      # stored one — computed fields are recomputed at fire time — and
      # overwriting it here would show the overlay a stale value the published
      # artifact disagrees with, which is precisely what this bridge exists to
      # prevent.
      conn
      # Per-caller draft content: never cache in a shared cache.
      |> put_resp_header("cache-control", "no-store")
      |> json(VisualEditing.annotate(json))
    else
      false ->
        not_found(conn, "Visual editing is disabled.")

      {:error, :invalid_preview} ->
        ApiError.send(conn, :not_found, "invalid_preview", "Invalid or expired preview token.")

      _ ->
        not_found(conn, "Content not found.")
    end
  end

  defp fetch(conn, ct, slug, params, org_id) do
    case preview_token(conn, params) do
      nil ->
        locale = Params.string(params, "locale", KilnCMS.I18n.default_locale())

        case fetch_by_slug(ct.type, slug, locale, Ash.PlugHelpers.get_actor(conn), org_id) do
          nil -> :error
          record -> {:ok, record}
        end

      token ->
        fetch_by_token(token, ct, slug, Params.string(params, "locale", nil), org_id)
    end
  end

  # The header first: a query string is what access logs and `Referer`s keep.
  defp preview_token(conn, params) do
    case get_req_header(conn, @token_header) do
      [token | _] when token != "" -> token
      _ -> Params.string(params, "preview_token", nil)
    end
  end

  # The token names the record by id; the route still has to agree with it on
  # everything else it says. The type and the site are the token's own claims
  # (a token for a post is no key to a page, and one minted on another site is
  # refused on this host — `KilnCMSWeb.PreviewController` holds the same line),
  # and the slug — plus the locale, when the caller names one — must be that
  # record's, so a token cannot be replayed under another document's URL.
  #
  # `authorize?: false`: the caller holds no actor — the grant is the signature
  # `PreviewToken.verify/1` checked, which binds this read to the ONE record id
  # an editor with draft visibility (`PreviewToken.mint/3`) minted it for. The
  # tenant is the serving org, which the token's `org_id` has just been pinned
  # to, so the bypassed read cannot reach another site's row.
  defp fetch_by_token(token, ct, slug, locale, org_id) do
    with {:ok, %{type: type, id: id, org_id: ^org_id}} <- PreviewToken.verify(token),
         true <- type == to_string(ct.type),
         {:ok, record} <-
           ContentTypes.get_record(ct, id,
             authorize?: false,
             tenant: org_id,
             load: [:featured_image] ++ KilnCMS.Seo.Patterns.loads()
           ),
         true <- record.slug == slug,
         true <- is_nil(locale) or record.locale == locale do
      {:ok, WorkingCopy.view(record)}
    else
      _ -> {:error, :invalid_preview}
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
        ContentTypes.get_record!(kind, id,
          actor: actor,
          tenant: org_id,
          # `:effective_seo_description` (#1102) for the same reason
          # `KilnCMS.Firing.References.load_published/3` carries it: a preview
          # fire that resolved the type's pattern against an unloaded category
          # would show the overlay a `description` the published artifact
          # disagrees with, which is what this bridge exists to prevent.
          load: [:featured_image] ++ KilnCMS.Seo.Patterns.loads()
        )

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp not_found(conn, message) do
    ApiError.send(conn, :not_found, "not_found", message)
  end
end
