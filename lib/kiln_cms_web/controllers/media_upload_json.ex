defmodule KilnCMSWeb.MediaUploadJSON do
  @moduledoc """
  Response bodies for `KilnCMSWeb.MediaUploadController`.

  A created item is rendered as a **JSON:API resource object** — the same
  `type`, `id`, attribute names and `tags` relationship
  `GET /api/json/media-items/:id` answers — so a client parses an upload's
  response with the code it already reads the library with, and can follow
  `links.self` to that route. It is written out here rather than run through
  AshJsonApi's serializer, which needs the JSON:API request it was routed
  from; `test/kiln_cms_web/controllers/media_upload_controller_test.exs` pins
  the attribute list to the JSON:API route's, so the two cannot drift apart
  silently.

  `meta.processing` is the one field the JSON:API route has no equivalent
  for: `true` while an A/V upload's metadata strip is still pending (#1122) —
  the row exists and is editor-readable, but its `url` serves nothing until
  the strip worker promotes the stripped copy.
  """

  # `MediaItem`'s public attributes, in the order the JSON:API route lists
  # them. `kind` is a calculation, which the JSON:API route serializes only on
  # request (`fields[media_item]=kind`); it is included here because a client
  # that just uploaded a file wants to know what the server decided it was.
  @attributes [
    :filename,
    :content_type,
    :byte_size,
    :width,
    :height,
    :duration_seconds,
    :variants,
    :alt,
    :caption,
    :decorative,
    :url,
    :focal_x,
    :focal_y,
    :audience,
    :download_count,
    :uploaded_by_id
  ]

  @doc false
  @spec attribute_names() :: [atom()]
  def attribute_names, do: @attributes

  @doc "A created media item as `{\"data\": <resource object>}`."
  @spec show(struct()) :: map()
  def show(item), do: %{data: resource(item)}

  defp resource(item) do
    %{
      type: "media_item",
      id: item.id,
      attributes:
        @attributes
        |> Map.new(&{&1, Map.get(item, &1)})
        |> Map.put(:kind, KilnCMS.MediaKind.of(item.content_type)),
      relationships: relationships(item.tags),
      links: %{self: "/api/json/media-items/#{item.id}"},
      meta: %{processing: item.quarantined}
    }
  end

  # Unloaded (the load after create failed) is not "no tags" — leave the
  # relationship out rather than claim an empty set.
  defp relationships(tags) when is_list(tags),
    do: %{tags: %{data: Enum.map(tags, &%{type: "tag", id: &1.id})}}

  defp relationships(_not_loaded), do: %{}

  @doc "An issued direct upload (`KilnCMS.Media.DirectUpload.begin/3`)."
  @spec direct(map()) :: map()
  def direct(upload) do
    %{
      data: %{
        token: upload.token,
        upload_url: upload.upload_url,
        method: upload.method,
        headers: upload.headers,
        expires_at: upload.expires_at,
        max_bytes: upload.max_bytes
      }
    }
  end
end
