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
    with {:ok, %{type: type, id: id, org_id: org_id}} <- PreviewToken.verify(token),
         :ok <- same_site(org_id, conn.assigns[:current_org]),
         {:ok, record} <- fetch(type, id, org_id) do
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
  #
  # A token minted on one site and presented on another's host is refused
  # (same as `ReleasePreviewLive`): the record must belong to the site that
  # serves it, or a draft would be served under another tenant's name.
  defp same_site(org_id, %{id: org_id}), do: :ok
  defp same_site(_org_id, _org), do: :error

  # `authorize?: false` (moduledoc): the caller is anonymous — no actor — and the
  # grant is the `Phoenix.Token` signature `PreviewToken.verify/1` checked above,
  # which binds the read to the ONE record id an editor minted it for. The
  # token's `org_id` is the tenant (#1309): content is org-scoped, so a
  # tenant-less read would be refused under strict tenancy, and `same_site/2`
  # has already pinned it to the serving org.
  defp fetch(type, id, org_id) do
    if ContentTypes.type?(type),
      do:
        ContentTypes.get_record(type, id,
          authorize?: false,
          tenant: org_id,
          # The payload carries both the stored SEO fields and their effective
          # values (#1102); loading the calculations here is what lets
          # `[category]` and `[field:<name>]` resolve to what the delivered page
          # shows, rather than to what a record read with no loads can see.
          load: KilnCMS.Seo.Patterns.loads([:seo_title, :seo_description])
        ),
      else: {:error, :unknown_type}
  end
end
