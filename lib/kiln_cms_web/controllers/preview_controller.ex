defmodule KilnCMSWeb.PreviewController do
  @moduledoc """
  Serves unpublished content for a valid signed preview token (see
  `KilnCMS.CMS.PreviewToken`). The token authorizes the read, so content is
  loaded with `authorize?: false`.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.CMS
  alias KilnCMS.CMS.PreviewToken

  @public_fields [
    :id,
    :title,
    :slug,
    :excerpt,
    :blocks,
    :seo_title,
    :seo_description,
    :locale,
    :state,
    :published_at,
    :scheduled_at,
    :inserted_at,
    :updated_at
  ]

  def show(conn, %{"token" => token}) do
    with {:ok, %{type: type, id: id}} <- PreviewToken.verify(token),
         {:ok, record} <- fetch(type, id) do
      json(conn, %{data: serialize(record)})
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Invalid or expired preview link"})
    end
  end

  defp fetch(:page, id), do: CMS.get_page(id, authorize?: false)
  defp fetch(:post, id), do: CMS.get_post(id, authorize?: false)
  defp fetch(_, _), do: {:error, :not_found}

  defp serialize(record) do
    record
    |> Map.take(@public_fields)
    |> Map.update(
      :blocks,
      [],
      &Enum.map(&1, fn block -> Map.take(block, [:type, :content, :data, :order, :children]) end)
    )
  end
end
