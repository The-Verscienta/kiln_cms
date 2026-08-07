defmodule KilnCMS.Blocks.File do
  @moduledoc """
  A downloadable document attachment (#481, Kiln v2 typed block).

  Unlike `KilnCMS.Blocks.Image`, this block never stores a direct storage
  URL — a gated `MediaItem` (#481) has no public URL to store, and even an
  ungated one needs the download counted and served with the *original*
  filename (not the UUID storage key). `render/2`'s href is always
  `/media/<media_id>/download`, built from `media_id` alone; the actual
  bytes, authorization, and `Content-Disposition` are
  `KilnCMSWeb.MediaDownloadController`'s job, resolved fresh on every click
  rather than baked in at render time — the one thing this block genuinely
  cannot get wrong by going stale.

  `title`/`filename`/`content_type`/`byte_size` are a denormalized snapshot
  of the `MediaItem` picked at insert time — the same choice
  `KilnCMS.Blocks.Image` makes for `alt`/`caption` rather than re-reading the
  library at render time (a block struct's `render/2` is a pure function
  with no database access). A later edit to the library item's own filename
  doesn't retroactively change what an already-placed block displays; picking
  a different file replaces the block instead.
  """
  use Kiln.Block

  block :file do
    # Not required — the editor inserts a placeholder, then fills it from the
    # media library (same pattern as image.ex's optional `url`).
    field :media_id, :string
    # Display title; defaults to `filename` when blank (set at insert time by
    # the picker, not re-derived here, so an editor can still override it).
    field :title, :string
    field :description, :string
    field :filename, :string
    field :content_type, :string
    field :byte_size, :integer
  end

  # Match a plain variable, not %__MODULE__{} — see the note in divider.ex: the
  # block struct isn't available when these heads compile (clean-compile only).
  @impl Kiln.Block.Renderer
  def render(block, :web) do
    if blank?(block.media_id) do
      ["<div class=\"kiln-file\"></div>"]
    else
      [
        "<div class=\"kiln-file\"><a href=\"",
        esc(download_href(block.media_id)),
        "\" download>",
        esc(display_title(block)),
        "</a>",
        badge_html(block),
        description_html(block),
        "</div>"
      ]
    end
  end

  def render(block, :json) do
    if blank?(block.media_id) do
      %{"_type" => "file"}
    else
      %{
        "_type" => "file",
        "media_id" => block.media_id,
        "download_url" => download_href(block.media_id)
      }
      |> put_if("title", display_title(block))
      |> put_if("description", block.description)
      |> put_if("filename", block.filename)
      |> put_if("content_type", block.content_type)
      |> put_if("byte_size", block.byte_size)
    end
  end

  # Not schema.org-worthy on its own — a download link, not a document
  # a search engine should index as a discrete entity.
  def render(_block, :json_ld), do: nil

  # The delivery payload adds a resolved `download_url` the DSL has no field
  # for, and every other key is conditional (`put_if`), so nothing beyond
  # `_type` is required — including `media_id`, which a placeholder block that
  # was never filled in does not carry.
  @impl Kiln.Block.Renderer
  def json_schema do
    %{
      "properties" => %{
        "download_url" => %{
          "type" => "string",
          "format" => "uri-reference",
          "description" => "Delivery href for the attachment, resolved from `media_id`."
        }
      }
    }
  end

  @impl Kiln.Block.Renderer
  def search_text(block) do
    [display_title(block), block.description]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  @doc "The `:llm` surface: a Markdown link, so an extracting engine sees a real link, not a bare id."
  def to_markdown(block) do
    if blank?(block.media_id),
      do: "",
      else: "[#{display_title(block)}](#{download_href(block.media_id)})"
  end

  defp display_title(block) do
    case block.title do
      nil -> block.filename || ""
      "" -> block.filename || ""
      title -> title
    end
  end

  defp download_href(media_id), do: "/media/#{media_id}/download"

  defp badge_html(block) do
    case block.byte_size do
      nil -> []
      size -> ["<span class=\"kiln-file-size\">", esc(humanize_bytes(size)), "</span>"]
    end
  end

  defp description_html(block) do
    case block.description do
      d when d in [nil, ""] -> []
      d -> ["<p class=\"kiln-file-description\">", esc(d), "</p>"]
    end
  end

  defp humanize_bytes(b) when b < 1_024, do: "#{b} B"
  defp humanize_bytes(b) when b < 1_048_576, do: "#{Float.round(b / 1_024, 1)} KB"
  defp humanize_bytes(b), do: "#{Float.round(b / 1_048_576, 1)} MB"

  defp put_if(map, _key, nil), do: map
  defp put_if(map, _key, ""), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp blank?(value), do: is_nil(value) or (is_binary(value) and String.trim(value) == "")

  defp esc(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
