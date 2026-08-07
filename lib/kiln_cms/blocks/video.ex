defmodule KilnCMS.Blocks.Video do
  @moduledoc """
  A self-hosted video player (#494, Kiln v2 typed block).

  Distinct from `KilnCMS.Blocks.Embed`, which points at YouTube/Vimeo: this
  one plays a `MediaItem` out of Kiln's own library, so it works for content
  that must not live on a third-party platform and it honours the item's
  `audience` gate.

  ## The `src` is always a route, never a stored URL

  Like `KilnCMS.Blocks.File` and unlike `KilnCMS.Blocks.Image`, this block
  never denormalizes a storage URL. A gated item has no public URL to store,
  and an item that gets gated *after* the block was placed would leave a baked
  URL pointing at a blob that has since moved to private storage. So `src` is
  always `/media/<media_id>/stream`, resolved fresh by
  `KilnCMSWeb.MediaDownloadController.stream/2` on every request — which is
  also the only way a `Range` request (seeking) reaches something that can
  answer it.

  `url` remains for the case with no library item at all: an editor pasting a
  direct link to a video hosted elsewhere. It is used only when `media_id` is
  blank, and is sanitized on the way out like any other author-supplied URL.

  ## Poster and captions

  `poster_media_id` is a still image shown before playback. A public video
  gets one generated automatically (`KilnCMS.Media.AVWorker`), which the
  picker pre-fills; an editor can always override it, and for a gated video —
  which never gets a generated poster, since the poster blob would be public —
  choosing one is the only way to have one.

  `captions_media_id` points at a WebVTT track in the library, rendered as a
  `<track kind="captions" default>`. This is the block's accessibility story
  and the reason a `.vtt` is a first-class upload rather than something an
  editor has to host elsewhere: a video with no captions and no transcript is
  simply not available to a deaf reader.
  """
  use Kiln.Block

  # `safe_image_src/1` is a scheme filter (relative paths and http(s) only),
  # not an image-specific check — it is the right guard for a `<video src>`
  # and a `<track src>` too, despite the name.
  alias KilnCMS.HTMLSanitizer

  block :video do
    # Not required — the editor inserts a placeholder, then fills it from the
    # media library (same pattern as image.ex's optional `url`).
    field :media_id, :string
    # An external direct URL, used ONLY when `media_id` is blank — see the
    # moduledoc on why a library item never gets its URL baked in here.
    field :url, :string
    field :title, :string
    field :caption, :string
    field :poster_media_id, :string
    field :poster_url, :string
    field :captions_media_id, :string
    field :captions_label, :string
    field :captions_lang, :string
    # Snapshot of the item's probed duration at pick time — used for the
    # `:json_ld` VideoObject and the editor's summary line, not for playback.
    field :duration_seconds, :float
    # Playback flags. `autoplay` deliberately has no counterpart flag to
    # unmute: an autoplaying video with sound is blocked by every browser and
    # unwelcome in the ones that allow it, so autoplay always implies muted.
    field :autoplay, :boolean, default: false
    field :loop, :boolean, default: false
  end

  # Match a plain variable, not %__MODULE__{} — see the note in divider.ex: the
  # block struct isn't available when these heads compile (clean-compile only).
  @impl Kiln.Block.Renderer
  def render(block, :web) do
    case src(block) do
      nil ->
        ["<div class=\"kiln-video\"></div>"]

      src ->
        [
          "<figure class=\"kiln-video\">",
          title_html(block),
          "<video src=\"",
          esc(src),
          "\" controls playsinline preload=\"metadata\"",
          poster_attr(block),
          flag_attrs(block),
          ">",
          track_html(block),
          "</video>",
          caption_html(block),
          "</figure>"
        ]
    end
  end

  def render(block, :json) do
    case src(block) do
      nil ->
        %{"_type" => "video"}

      src ->
        %{"_type" => "video", "src" => src}
        |> put_if("media_id", block.media_id)
        |> put_if("title", block.title)
        |> put_if("caption", block.caption)
        |> put_if("poster", poster_src(block))
        |> put_if("captions_url", captions_src(block))
        |> put_if("captions_label", block.captions_label)
        |> put_if("captions_lang", block.captions_lang)
        |> put_if("duration_seconds", block.duration_seconds)
        |> Map.put("autoplay", block.autoplay == true)
        |> Map.put("loop", block.loop == true)
    end
  end

  # A VideoObject is worth emitting: unlike a download link, a video IS a
  # discrete entity a search engine indexes. `name` and `description` are
  # required by the schema, so nothing is emitted without a title.
  def render(block, :json_ld) do
    with src when is_binary(src) <- src(block),
         title when is_binary(title) and title != "" <- presence(block.title) do
      %{"@type" => "VideoObject", "name" => title, "contentUrl" => src}
      |> put_if("description", block.caption)
      |> put_if("thumbnailUrl", poster_src(block))
      |> put_if("duration", iso8601_duration(block.duration_seconds))
    else
      _ -> nil
    end
  end

  # Same projection as `audio`, one level deeper: the poster and captions each
  # collapse a `*_media_id`/`*_url` pair into one resolved href.
  @impl Kiln.Block.Renderer
  def json_schema do
    %{
      "x-kiln-drop" => ["url", "poster_media_id", "poster_url", "captions_media_id"],
      "properties" => %{
        "src" => Kiln.Block.JsonSchema.resolved_src(),
        "poster" => %{"type" => "string", "format" => "uri-reference"},
        "captions_url" => %{"type" => "string", "format" => "uri-reference"},
        "autoplay" => %{"type" => "boolean", "default" => false},
        "loop" => %{"type" => "boolean", "default" => false}
      }
    }
  end

  @impl Kiln.Block.Renderer
  def search_text(block) do
    [block.title, block.caption] |> Enum.reject(&blank?/1) |> Enum.join(" ")
  end

  @doc "The `:llm` surface: the title and caption, plus the URL so an extracting engine sees a real link."
  def to_markdown(block) do
    case src(block) do
      nil -> search_text(block)
      src -> "[#{presence(block.title) || "Video"}](#{src})" |> with_caption(block.caption)
    end
  end

  defp with_caption(markdown, caption) do
    if blank?(caption), do: markdown, else: markdown <> "\n\n" <> caption
  end

  # A library item always streams through the app route; a pasted URL is only
  # consulted when there is no item, and is scheme-filtered so `javascript:`
  # and friends can never reach a rendered attribute.
  defp src(block) do
    cond do
      not blank?(block.media_id) -> stream_href(block.media_id)
      not blank?(block.url) -> HTMLSanitizer.safe_image_src(block.url)
      true -> nil
    end
  end

  defp poster_src(block) do
    cond do
      not blank?(block.poster_media_id) -> stream_href(block.poster_media_id)
      not blank?(block.poster_url) -> HTMLSanitizer.safe_image_src(block.poster_url)
      true -> nil
    end
  end

  defp captions_src(block) do
    if blank?(block.captions_media_id), do: nil, else: stream_href(block.captions_media_id)
  end

  defp stream_href(media_id), do: "/media/#{media_id}/stream"

  defp poster_attr(block) do
    case poster_src(block) do
      nil -> []
      poster -> [" poster=\"", esc(poster), "\""]
    end
  end

  # `autoplay` forces `muted`: browsers block an unmuted autoplay outright, so
  # emitting one produces a player that silently refuses to start.
  defp flag_attrs(block) do
    [
      if(block.autoplay == true, do: " autoplay muted", else: []),
      if(block.loop == true, do: " loop", else: [])
    ]
  end

  defp track_html(block) do
    case captions_src(block) do
      nil ->
        []

      src ->
        [
          "<track kind=\"captions\" src=\"",
          esc(src),
          "\" srclang=\"",
          esc(presence(block.captions_lang) || "en"),
          "\" label=\"",
          esc(presence(block.captions_label) || "Captions"),
          "\" default/>"
        ]
    end
  end

  # The audio block's counterpart, and present for the same reason: the editor
  # offers a Title field, so the `:web` surface has to render it or the field
  # is a place to type text that silently never appears.
  defp title_html(block) do
    case presence(block.title) do
      nil -> []
      title -> ["<p class=\"kiln-video-title\">", esc(title), "</p>"]
    end
  end

  defp caption_html(block) do
    case presence(block.caption) do
      nil -> []
      caption -> ["<figcaption>", esc(caption), "</figcaption>"]
    end
  end

  # schema.org wants an ISO 8601 duration; `MediaKind.humanize_duration/1`'s
  # `m:ss` is for humans and is not interchangeable with it.
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
