defmodule KilnCMSWeb.PreviewController do
  @moduledoc """
  Serves unpublished content for a valid signed preview token (see
  `KilnCMS.CMS.PreviewToken`). The token authorizes the read, so content is
  loaded with `authorize?: false`.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.CMS.ContentSerializer
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.PreviewToken

  def show(conn, %{"token" => token}) do
    with {:ok, %{type: type, id: id}} <- PreviewToken.verify(token),
         {:ok, record} <- fetch(type, id) do
      json(conn, %{data: ContentSerializer.to_map(record)})
    else
      _ ->
        # Standard error envelope shared across the headless surfaces (#190).
        conn
        |> put_status(:not_found)
        |> json(%{
          errors: [
            %{status: "404", code: "invalid_preview", detail: "Invalid or expired preview link."}
          ]
        })
    end
  end

  # The token carries the content type; resolve it generically via the registry.
  defp fetch(type, id) do
    if ContentTypes.type?(type),
      do: ContentTypes.get_record(type, id, authorize?: false),
      else: {:error, :unknown_type}
  end
end
