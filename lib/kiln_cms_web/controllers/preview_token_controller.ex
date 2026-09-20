defmodule KilnCMSWeb.PreviewTokenController do
  @moduledoc """
  Mint a draft preview link over the API:
  `POST /api/content/:type/:id/preview-token`.

  The headless half of the content editor's *Copy preview link*: a front end's
  draft mode (or any integration holding an editor's API key or bearer token)
  asks for a short-lived token for one document, then hands the **token** —
  never its own credential — to the browser, which redeems it at
  `GET /preview/:token`. See `KilnCMS.CMS.PreviewToken` for what the token
  grants and `KilnCMS.CMS.PreviewToken.mint/3` for who may mint one.

  Authenticated by the `:api` pipeline (`Authorization: Bearer <jwt | kiln_…>`).
  A `:read`-scoped API key is enough: the token grants a read, so minting one
  is distribution of what the key can already see, never a write.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.CMS.PreviewToken
  alias KilnCMSWeb.ApiError

  def create(conn, %{"type" => type, "id" => id}) do
    case Ash.PlugHelpers.get_actor(conn) do
      nil ->
        ApiError.send(
          conn,
          :unauthorized,
          "unauthorized",
          "Minting a preview link needs an API key or bearer token."
        )

      actor ->
        type
        |> PreviewToken.mint(id, actor: actor, tenant: conn.assigns[:current_org])
        |> respond(conn)
    end
  end

  defp respond({:ok, minted}, conn) do
    conn
    # A bearer credential for a draft: never in a shared cache.
    |> put_resp_header("cache-control", "private, no-store")
    |> put_status(:created)
    |> json(%{
      token: minted.token,
      url: minted.url,
      type: minted.type,
      id: minted.id,
      expires_at: DateTime.to_iso8601(minted.expires_at),
      expires_in: PreviewToken.max_age_seconds()
    })
  end

  # Readable, but not as an editor: the caller already knows the document
  # exists, so saying why is no disclosure.
  defp respond({:error, :forbidden}, conn) do
    ApiError.send(
      conn,
      :forbidden,
      "forbidden",
      "Only an editor who can see this document's draft can share a preview of it."
    )
  end

  # Unknown type, no such record, or one the caller cannot read at all — one
  # answer for all three, so the endpoint confirms nothing about drafts.
  defp respond({:error, :not_found}, conn),
    do: ApiError.send(conn, :not_found, "not_found", "Content not found.")
end
