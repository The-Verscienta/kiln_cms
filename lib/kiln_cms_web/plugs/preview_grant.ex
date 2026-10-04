defmodule KilnCMSWeb.Plugs.PreviewGrant do
  @moduledoc """
  Turns a preview token presented on a headless **read** into a
  `KilnCMS.CMS.PreviewGrant` for the one record it names.

  A front end rendering a shared draft in its own templates makes the same
  calls it makes for a published page — `GET /api/json/<plural>?filter[slug]=…`
  with `include=content_links,…`, and `GET /api/content/:type/:slug?surface=…`
  — and adds the token (`x-kiln-preview-token`, or `?preview_token=` for a
  client that cannot set headers; the header wins, since a query string is what
  access logs and `Referer`s keep). This plug verifies it once, then:

    * assigns the grant as `conn.assigns.kiln_preview_grant`
      (`KilnCMSWeb.ArtifactController` renders the working copy live from it);
    * merges it into the request's Ash context, which `ash_json_api` hands to
      the read and its relationship loads, where `KilnCMS.CMS.Checks.PreviewGrant`
      admits the record and `KilnCMS.CMS.Checks.LinkEndsReadable` its edges.

  The caller's own identity is untouched: the grant only adds a row.

  A presented token is the **only** preview credential consulted. One that does
  not verify, belongs to another site, or names a type this site does not have
  is answered `404 invalid_preview` and the request halts — never a silent
  fallback to the published page, so a front end whose link lapsed learns it
  rather than showing readers the live version as if it were the draft.

  Only `GET`/`HEAD` carry a grant: on a write the token is ignored, so no write
  ever runs with one. Requests that present a token are charged to the
  `:preview_api` bucket on top of `:api` — one page render is several calls,
  all from the front end's server.
  """
  import Plug.Conn

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.PreviewGrant
  alias KilnCMS.CMS.PreviewToken
  alias KilnCMSWeb.ApiError

  @token_header "x-kiln-preview-token"
  @token_param "preview_token"

  @doc "The request header a preview token is read from."
  @spec token_header() :: String.t()
  def token_header, do: @token_header

  @doc "The query parameter a preview token is read from when the header is absent."
  @spec token_param() :: String.t()
  def token_param, do: @token_param

  @doc """
  The preview token a request presents, header first, or nil. Shared with
  `KilnCMSWeb.VisualEditingController`.
  """
  @spec presented_token(Plug.Conn.t()) :: String.t() | nil
  def presented_token(conn) do
    case get_req_header(conn, @token_header) do
      [token | _] when token != "" ->
        token

      _ ->
        case fetch_query_params(conn).query_params do
          %{@token_param => token} when is_binary(token) and token != "" -> token
          _ -> nil
        end
    end
  end

  def init(opts), do: opts

  def call(%{method: method} = conn, _opts) when method in ~w(GET HEAD) do
    case presented_token(conn) do
      nil -> conn
      token -> conn |> drop_token_param() |> charge() |> grant(token)
    end
  end

  def call(conn, _opts), do: conn

  # The query parameter is ours, not the read's: `ash_json_api` would try to
  # parse it, so it leaves `query_params`/`params` once read.
  defp drop_token_param(conn) do
    %{
      conn
      | query_params: Map.delete(conn.query_params, @token_param),
        params: drop_param(conn.params)
    }
  end

  defp drop_param(%{} = params), do: Map.delete(params, @token_param)
  defp drop_param(params), do: params

  defp charge(conn), do: KilnCMSWeb.Plugs.RateLimit.call(conn, :preview_api)

  defp grant(%{halted: true} = conn, _token), do: conn

  defp grant(conn, token) do
    org_id = KilnCMSWeb.Tenant.current_org_id(conn)

    with {:ok, %{type: type, id: id, org_id: ^org_id}} <- PreviewToken.verify(token),
         %{} = ct <- ContentTypes.get(type, org_id),
         resource when not is_nil(resource) <- resource(ct) do
      grant = %PreviewGrant{type: type, id: id, org_id: org_id, resource: resource}

      conn
      |> assign(:kiln_preview_grant, grant)
      |> Ash.PlugHelpers.set_context(merge_context(Ash.PlugHelpers.get_context(conn), grant))
    else
      _ ->
        conn
        |> ApiError.send(:not_found, "invalid_preview", "Invalid or expired preview token.")
        |> halt()
    end
  end

  defp resource(%{source: :dynamic}), do: KilnCMS.CMS.Entry
  defp resource(%{resource: resource}), do: resource

  # Keep whatever context an earlier plug set; only `shared` gains the grant.
  defp merge_context(nil, grant), do: PreviewGrant.context(grant)

  defp merge_context(context, grant) do
    %{shared: shared} = PreviewGrant.context(grant)
    Map.update(context, :shared, shared, &Map.merge(&1, shared))
  end
end
