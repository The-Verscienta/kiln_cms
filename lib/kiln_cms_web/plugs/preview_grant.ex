defmodule KilnCMSWeb.Plugs.PreviewGrant do
  @moduledoc """
  Turns a preview token on a headless read into a read grant for the one record
  it names (#1887): headless draft mode.

  A front end that renders pages from the plain reads — JSON:API by id with
  `include=`, and `GET /api/content/:type/:slug` for the body — can render a
  shared draft in its own templates by presenting the token it was handed,
  instead of holding an editor credential or redirecting to Kiln's own
  preview page. The token is read from `x-kiln-preview-token`, or from
  `?preview_token=` for a caller that cannot set headers (the header first: a
  query string is what access logs and `Referer`s keep).

  Every response through it says it varies on `x-kiln-preview-token`: the same
  URL answers the draft to a caller presenting one, so a cache holding the
  anonymous answer must not hand it on. Beyond that, only a `GET` or `HEAD`
  reads a token — a write is never widened by one, so on a write it is not
  consulted at all. With a token on a read, the plug:

    * charges the `:preview_api` rate-limit bucket, on top of the pipeline's
      own — a preview read renders live, never from a cache;
    * verifies the token and pins it to the serving site
      (`KilnCMS.CMS.PreviewGrant.verify/2`). A token that does not verify, has
      expired or was minted on another site is answered `404
      invalid_preview`, never a silent fall back to the anonymous read: a
      front end whose token lapsed must learn it has to re-mint, rather than
      quietly render the published page as if it were the draft;
    * assigns `:preview_grant` (for `KilnCMSWeb.ArtifactController` and
      `KilnCMSWeb.VisualEditingController`) and puts the grant in the Ash
      context's `:shared` key (for the JSON:API reads, where
      `KilnCMS.CMS.Checks.PreviewGrant` applies it);
    * marks the conn as carrying a credential (`credential?/1`), which
      `KilnCMSWeb.Plugs.PublicCache` reads, and the response
      `private, no-store` whatever a later plug or the handler chose: the body
      is a function of the token, not of the URL.

  Mounted on `/api/json`, the fired-artifact read and the visual-editing read.
  GraphQL, search and `/mcp` do not take a preview token, so a token sent
  there changes nothing about their answer or its caching.
  """
  @behaviour Plug

  import Plug.Conn

  alias KilnCMS.CMS.PreviewGrant
  alias KilnCMSWeb.ApiError
  alias KilnCMSWeb.Plugs.PublicCache

  @header "x-kiln-preview-token"
  @param "preview_token"

  @doc "The request header a preview token is read from."
  @spec header() :: String.t()
  def header, do: @header

  @doc "The query parameter a preview token is read from, for a caller that cannot set headers."
  @spec param() :: String.t()
  def param, do: @param

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = register_before_send(conn, &PublicCache.put_vary(&1, [@header]))

    case conn.method in ["GET", "HEAD"] and token(conn) do
      token when is_binary(token) -> grant(conn, token)
      _no_token_or_a_write -> conn
    end
  end

  @doc "Whether the plug admitted a preview token on `conn` — a per-caller answer."
  @spec credential?(Plug.Conn.t()) :: boolean()
  def credential?(conn), do: Map.has_key?(conn.assigns, :preview_grant)

  @doc "The preview token `conn` presents, or `nil`."
  @spec token(Plug.Conn.t()) :: String.t() | nil
  def token(conn) do
    case get_req_header(conn, @header) do
      [token | _] when token != "" ->
        token

      _ ->
        case fetch_query_params(conn).query_params do
          %{@param => token} when is_binary(token) and token != "" -> token
          _ -> nil
        end
    end
  end

  defp grant(conn, token) do
    conn = KilnCMSWeb.Plugs.RateLimit.call(conn, :preview_api)

    with false <- conn.halted,
         {:ok, grant} <- PreviewGrant.verify(token, KilnCMSWeb.Tenant.current_org_id(conn)) do
      conn
      |> assign(:preview_grant, grant)
      |> put_ash_context(grant)
      |> register_before_send(&put_resp_header(&1, "cache-control", "private, no-store"))
    else
      true ->
        conn

      {:error, :invalid} ->
        conn
        |> put_resp_header("cache-control", "private, no-store")
        |> ApiError.send(:not_found, "invalid_preview", "Invalid or expired preview token.")
        |> halt()
    end
  end

  # Merged into whatever context an earlier plug set, `:shared` included.
  defp put_ash_context(conn, grant) do
    context = Ash.PlugHelpers.get_context(conn) || %{}
    %{shared: shared} = PreviewGrant.context(grant)

    Ash.PlugHelpers.set_context(
      conn,
      Map.update(context, :shared, shared, &Map.merge(&1, shared))
    )
  end
end
