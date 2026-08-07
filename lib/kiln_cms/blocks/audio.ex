defmodule KilnCMS.Blocks.Audio do
  @moduledoc """
  A self-hosted audio player — a podcast episode, an interview, a pronunciation
  clip (#494, Kiln v2 typed block).

  The sibling of `KilnCMS.Blocks.Video` and structurally the same: `src` is
  always `/media/<media_id>/stream` for a library item (never a denormalized
  storage URL — see that module's moduledoc for why), falling back to `url`
  only when there is no library item at all.

  Deliberately smaller than the video block: no poster (an `<audio>` element
  has nowhere to put one) and no captions track. A transcript for an audio
  clip belongs in a `rich_text` block next to it, where it is readable,
  searchable and indexable — three things a `<track>` on an `<audio>` is not.
  """
  use Kiln.Block

  # See the note in video.ex: this is a scheme filter, not an image check.
  alias KilnCMS.HTMLSanitizer

  block :audio do
    field :media_id, :string
    field :url, :string
    field :title, :string
    field :caption, :string
    # Snapshot of the item's probed duration at pick time — display only.
    field :duration_seconds, :float
    field :loop, :boolean, default: false
  end

  # Match a plain variable, not %__MODULE__{} — see the note in divider.ex: the
  # block struct isn't available when these heads compile (clean-compile only).
  @impl Kiln.Block.Renderer
  def render(block, :web) do
    case src(block) do
      nil ->
        ["<div class=\"kiln-audio\"></div>"]

      src ->
        [
          "<figure class=\"kiln-audio\">",
          title_html(block),
          "<audio src=\"",
          esc(src),
          "\" controls preload=\"metadata\"",
          if(block.loop == true, do: " loop", else: []),
          "></audio>",
          caption_html(block),
          "</figure>"
        ]
    end
  end

  def render(block, :json) do
    case src(block) do
      nil ->
        %{"_type" => "audio"}

      src ->
        %{"_type" => "audio", "src" => src}
        |> put_if("media_id", block.media_id)
        |> put_if("title", block.title)
        |> put_if("caption", block.caption)
        |> put_if("duration_seconds", block.duration_seconds)
        |> Map.put("loop", block.loop == true)
    end
  end

  # An AudioObject, on the same reasoning as the video block's VideoObject:
  # a discrete entity worth indexing, but only once it has a name.
  def render(block, :json_ld) do
    with src when is_binary(src) <- src(block),
         title when is_binary(title) and title != "" <- presence(block.title) do
      %{"@type" => "AudioObject", "name" => title, "contentUrl" => src}
      |> put_if("description", block.caption)
      |> put_if("duration", iso8601_duration(block.duration_seconds))
    else
      _ -> nil
    end
  end

  # `media_id` and `url` are two authoring routes to one playable source; the
  # `:json` render resolves them into `src` and drops the raw `url`. A block
  # with neither renders `_type` alone, so nothing else is required.
  @impl Kiln.Block.Renderer
  def json_schema do
    %{
      "x-kiln-drop" => ["url"],
      "properties" => %{
        "src" => Kiln.Block.JsonSchema.resolved_src(),
        "loop" => %{"type" => "boolean", "default" => false}
      }
    }
  end

  @impl Kiln.Block.Renderer
  def search_text(block) do
    [block.title, block.caption] |> Enum.reject(&blank?/1) |> Enum.join(" ")
  end

  @doc "The `:llm` surface: a Markdown link, so an extracting engine sees a real link, not a bare id."
  def to_markdown(block) do
    case src(block) do
      nil -> search_text(block)
      src -> "[#{presence(block.title) || "Audio"}](#{src})" |> with_caption(block.caption)
    end
  end

  defp with_caption(markdown, caption) do
    if blank?(caption), do: markdown, else: markdown <> "\n\n" <> caption
  end

  defp src(block) do
    cond do
      not blank?(block.media_id) -> "/media/#{block.media_id}/stream"
      not blank?(block.url) -> HTMLSanitizer.safe_image_src(block.url)
      true -> nil
    end
  end

  defp title_html(block) do
    case presence(block.title) do
      nil -> []
      title -> ["<p class=\"kiln-audio-title\">", esc(title), "</p>"]
    end
  end

  defp caption_html(block) do
    case presence(block.caption) do
      nil -> []
      caption -> ["<figcaption>", esc(caption), "</figcaption>"]
    end
  end

  defp iso8601_duration(seconds) when is_number(seconds) and seconds > 0 do
    total = round(seconds)
    "PT#{div(total, 3600)}H#{total |> div(60) |> rem(60)}M#{rem(total, 60)}S"
  end

  defp iso8601_duration(_seconds), do: nil

  defp presence(value), do: if(blank?(value), do: nil, else: value)

  defp put_if(map, _key, nil), do: map
  defp put_if(map, _key, ""), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp blank?(value), do: is_nil(value) or (is_binary(value) and String.trim(value) == "")

  defp esc(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
