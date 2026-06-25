defmodule KilnCMS.Blocks.Image do
  @moduledoc "An image block (Kiln v2 typed block — D10). `url` is a media URL/id for now; Phase J wires first-class media."
  use Kiln.Block

  block :image do
    # Not required — the editor inserts a placeholder image block, then fills the
    # url from the media picker or a pasted URL.
    field :url, :string
    field :alt, :string
    field :caption, :string
    # Optional link to a MediaItem, so delivery can render responsive variants.
    field :media_id, :string
  end

  @impl Kiln.Block.Renderer
  def render(%__MODULE__{} = block, :web) do
    figure = ["<img src=\"", esc(block.url || ""), "\" alt=\"", esc(block.alt || ""), "\"/>"]

    case block.caption do
      nil -> ["<figure>", figure, "</figure>"]
      "" -> ["<figure>", figure, "</figure>"]
      caption -> ["<figure>", figure, "<figcaption>", esc(caption), "</figcaption></figure>"]
    end
  end

  def render(%__MODULE__{} = block, :json),
    do: %{"_type" => "image", "url" => block.url, "alt" => block.alt, "caption" => block.caption}

  def render(%__MODULE__{} = block, :json_ld) do
    %{"@type" => "ImageObject", "url" => block.url}
    |> put_if("caption", block.caption)
    |> put_if("name", block.alt)
  end

  @impl Kiln.Block.Renderer
  def search_text(%__MODULE__{alt: alt, caption: caption}),
    do: [alt, caption] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ")

  defp put_if(map, _key, nil), do: map
  defp put_if(map, _key, ""), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp esc(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
