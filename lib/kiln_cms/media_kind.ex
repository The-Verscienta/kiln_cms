defmodule KilnCMS.MediaKind do
  @moduledoc """
  Classifies a stored `MediaItem` by its `content_type` (#494).

  Before video and audio existed the library had exactly two buckets and
  `not ilike(content_type, "image/%")` was a perfectly good spelling of
  "document". It isn't any more: an MP4 is neither an image nor a document,
  and every place that asked the two-bucket question — the media library's
  preview, the editor's file picker, the content-editor search filters — would
  silently start offering videos as downloadable PDFs.

  So the question moves here, once, and the callers ask `of/1` instead. The
  buckets are:

    * `:image` — raster images, and anything with **no** `content_type` at
      all (a `nil`; a blank string is a `:document`, like any other
      unrecognized value).
      A NULL is an image because every row predating #481 was one, and seed
      data/tests still create rows without setting it (see `MediaItem`).
    * `:video`, `:audio` — playable media (#494).
    * `:captions` — a WebVTT track. Uploaded through the library like anything
      else, but it belongs to a `<video>`, not to a reader.
    * `:document` — the fallback: a PDF today, whatever `DocumentProcessor`
      grows to accept later.

  ## Trusting `content_type`

  It is byte-sniffed on upload, but it is also in `MediaItem`'s
  `default_accept`, so an editor with API access can set it to anything. That
  makes it fine for *classification* (the worst case is an item filed in the
  wrong picker) and **not** fine for anything security-bearing. The one place
  it would be — the `Content-Type` of an inline response — goes through
  `inline_streamable?/1` below rather than `of/1`, so an arbitrary string
  can't reach a response header by being classified into the right bucket.
  """

  @type t :: :image | :video | :audio | :captions | :document

  # Content types this application will serve **inline** (`Content-Disposition`
  # absent rather than `attachment`), which is what a `<video>`/`<audio>`/
  # `<track>` element needs. Exhaustive and exact-matched on purpose: these are
  # precisely the values `AVProcessor.validate_upload/1` produces, so an
  # editor-supplied `content_type` of `text/html` can never be echoed into an
  # inline response. Everything else is served as an attachment by
  # `KilnCMSWeb.MediaDownloadController`.
  @inline_streamable ~w(video/mp4 video/webm audio/mpeg audio/mp4 text/vtt)

  @doc """
  The bucket `content_type` belongs to. A **missing** (`nil`) type is an
  `:image` — see the moduledoc. A blank string is not: it is a real, stored,
  meaningless value, and the `:document` fallback is where every other
  unrecognized type goes.

  Matched case-insensitively, because the SQL twins of this function in
  `KilnCMSWeb.ContentEditorLive` use `ilike` — a row whose `content_type` was
  set to `"VIDEO/MP4"` through the API would otherwise be a video to the
  picker's query and a document to every Elixir caller.
  """
  @spec of(String.t() | nil) :: t()
  def of(content_type) when is_binary(content_type) do
    normalized = String.downcase(content_type)

    cond do
      String.starts_with?(normalized, "image/") -> :image
      normalized == "text/vtt" -> :captions
      String.starts_with?(normalized, "video/") -> :video
      String.starts_with?(normalized, "audio/") -> :audio
      true -> :document
    end
  end

  def of(_content_type), do: :image

  @doc "True for a video or audio item — the two kinds that render as a player."
  @spec playable?(String.t() | nil) :: boolean()
  def playable?(content_type), do: of(content_type) in [:video, :audio]

  @doc """
  Whether `content_type` may be sent **inline** with itself as the response
  `Content-Type`. Exact allowlist membership, never a prefix match — see the
  moduledoc's note on trusting `content_type`.
  """
  @spec inline_streamable?(String.t() | nil) :: boolean()
  def inline_streamable?(content_type) when is_binary(content_type),
    do: content_type in @inline_streamable

  def inline_streamable?(_content_type), do: false

  @doc "Every content type `inline_streamable?/1` accepts — for docs and tests."
  @spec inline_streamable_types() :: [String.t()]
  def inline_streamable_types, do: @inline_streamable

  @doc """
  Formats a duration in seconds as `m:ss` (or `h:mm:ss` past an hour) for
  display next to a player. `nil` in, `nil` out — an unprobed item shows
  nothing rather than `0:00`, which would read as an empty file.
  """
  @spec humanize_duration(number() | nil) :: String.t() | nil
  def humanize_duration(seconds) when is_number(seconds) and seconds >= 0 do
    total = round(seconds)
    {h, m, s} = {div(total, 3600), total |> div(60) |> rem(60), rem(total, 60)}

    if h > 0,
      do: "#{h}:#{pad(m)}:#{pad(s)}",
      else: "#{m}:#{pad(s)}"
  end

  def humanize_duration(_seconds), do: nil

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
