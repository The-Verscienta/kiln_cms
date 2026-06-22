defmodule KilnCMSWeb.PreviewController do
  @moduledoc """
  Serves unpublished content for a valid signed preview token (see
  `KilnCMS.CMS.PreviewToken`). The token authorizes the read, so content is
  loaded with `authorize?: false`.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentSerializer
  alias KilnCMS.CMS.PreviewToken

  def show(conn, %{"token" => token}) do
    with {:ok, %{type: type, id: id}} <- PreviewToken.verify(token),
         {:ok, record} <- fetch(type, id) do
      json(conn, %{data: ContentSerializer.to_map(record)})
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Invalid or expired preview link"})
    end
  end

  # `PreviewToken.verify/1` only ever yields `:page` or `:post`.
  defp fetch(:page, id), do: CMS.get_page(id, authorize?: false)
  defp fetch(:post, id), do: CMS.get_post(id, authorize?: false)
end
