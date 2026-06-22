defmodule KilnCMS.CMS.ContentSerializer do
  @moduledoc """
  Serializes a Page/Post into a plain map of public fields — used by the
  preview endpoint and webhook payloads. Internal fields (e.g. `search_text`)
  are never included.
  """

  @public_fields [
    :id,
    :title,
    :slug,
    :excerpt,
    :blocks,
    :seo_title,
    :seo_description,
    :seo_image,
    :canonical_url,
    :locale,
    :state,
    :published_at,
    :scheduled_at,
    :inserted_at,
    :updated_at
  ]

  @block_fields [:type, :content, :data, :order, :children]

  @doc "Curated public map for a Page/Post record."
  @spec to_map(struct()) :: map()
  def to_map(record) do
    record
    |> Map.take(@public_fields)
    |> Map.update(:blocks, [], fn blocks ->
      blocks |> List.wrap() |> Enum.map(&Map.take(&1, @block_fields))
    end)
  end
end
