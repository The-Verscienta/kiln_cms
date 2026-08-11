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
  alias KilnCMSWeb.ApiError

  # A browser opening a shared preview link lands on the human multiplayer
  # view (#379); headless consumers (JSON accept — the default) are unchanged.
  def show(%{private: %{phoenix_format: "html"}} = conn, %{"token" => token}) do
    redirect(conn, to: ~p"/preview/#{token}/live")
  end

  def show(conn, %{"token" => token}) do
    with {:ok, %{type: type, id: id}} <- PreviewToken.verify(token),
         {:ok, record} <- fetch(type, id) do
      json(conn, %{data: ContentSerializer.to_map(record)})
    else
      _ ->
        ApiError.send(
          conn,
          :not_found,
          "invalid_preview",
          "Invalid or expired preview link."
        )
    end
  end

  # The token carries the content type; resolve it generically via the registry.
  defp fetch(type, id) do
    if ContentTypes.type?(type),
      do:
        ContentTypes.get_record(type, id,
          authorize?: false,
          # The payload carries both the stored SEO fields and their effective
          # values (#1102); loading the calculations here is what lets
          # `[category]` and `[field:<name>]` resolve to what the delivered page
          # shows, rather than to what a record read with no loads can see.
          load: KilnCMS.Seo.Patterns.loads([:seo_title, :seo_description])
        ),
      else: {:error, :unknown_type}
  end
end
