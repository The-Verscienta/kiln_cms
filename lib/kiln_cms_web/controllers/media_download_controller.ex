defmodule KilnCMSWeb.MediaDownloadController do
  @moduledoc """
  Serves a `MediaItem`'s bytes for download (#481) — the one path every
  document link in the app points at, `:file` block included, gated or not.

  ## Why every document goes through here, not a direct storage URL

  Three things a raw `Storage.url/1` link can't do, all of which need the
  request to pass through the app first:

    * **authorization** — a gated item's bytes live in private storage
      specifically so nothing *but* this controller's policy-checked read
      (`CMS.get_media_item/2`, ordinary actor/tenant, no bespoke auth
      mechanism) can reach them;
    * **the original filename** — `Storage.store/2` writes under a UUID key,
      so a direct link would prompt to save as `3f2a...-c1.pdf` rather than
      the document's real name;
    * **the download counter** — one choke point to bump
      `MediaItem.download_count` from, matching how `KilnCMSWeb.ViewTracking`
      is the one choke point for content views.

  A denied or missing item renders 404, not 403 — `CMS.get_media_item/2`'s
  policy-checked read naturally can't tell the two apart (a gated row simply
  isn't in the actor's readable set), and that's the right answer here too:
  confirming a gated document *exists* is itself information a reader
  without its audience shouldn't get for free.

  ## Two actions, and why they differ (#494)

  `show/2` is the download path above: whole blob, `Content-Disposition:
  attachment`, counter bumped.

  `stream/2` serves the same authorized bytes for **playback** — the `src` of
  every `video`/`audio` block and the `src` of their `<track>`. It differs on
  three points, each forced by what a media element actually does:

    * **inline, not `attachment`** — a `<video>` can't play a response the
      browser is told to save. Only content types on
      `KilnCMS.MediaKind.inline_streamable?/1`'s exact allowlist are served
      this way; anything else falls back to `show/2`'s attachment posture, so
      an editor-supplied `content_type` can't turn this into an
      arbitrary-HTML host on the app's own origin.
    * **`Range` requests** — seeking in a video is a `Range:` request, and a
      player will not expose a scrub bar at all without `Accept-Ranges`.
      Answered from `Storage.fetch_range/3`, which reads only the requested
      slice rather than pulling a whole file into memory per seek.
    * **no download counter** — scrubbing through one video issues dozens of
      ranged requests. Counting those as downloads would make the number
      meaningless, so `download_count` stays a download-only measure.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.CMS
  alias KilnCMS.MediaKind
  alias KilnCMS.Storage

  # The most bytes this module will ever hold in memory at once, and the
  # ceiling on a single ranged response.
  #
  # It has to be BOTH, because otherwise it is neither. A cap applied only to
  # ranged reads is bypassed by simply not sending a `Range` header — or by
  # sending an unparseable one — and a 500 MB video (`MediaLive`'s video cap)
  # would then be one anonymous request away from 500 MB of BEAM heap, times
  # however many requests are in flight. So the un-ranged path streams in
  # chunks of this size rather than reading the blob whole, and the ranged
  # path clamps to it. A 206 shorter than requested is ordinary; a player
  # handles it by asking for the next slice.
  @max_chunk 8 * 1024 * 1024

  def show(conn, %{"id" => id}) do
    with_item(conn, id, &serve/3)
  end

  @doc """
  Serves a media item inline for playback, honouring `Range` (#494).

  Same authorization as `show/2` — the ordinary policy-checked read, so a
  gated item is reachable only by an actor holding its audience, and a denied
  or missing item is a 404 either way.
  """
  def stream(conn, %{"id" => id}) do
    with_item(conn, id, &serve_stream/3)
  end

  defp with_item(conn, id, serve_fun) do
    actor = conn.assigns[:current_user]
    org_id = KilnCMSWeb.Tenant.current_org_id(conn)

    case CMS.get_media_item(id, actor: actor, tenant: org_id) do
      {:ok, item} -> serve_fun.(conn, item, org_id)
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  # `bytes` is the stored blob, sent with an explicit Content-Disposition:
  # attachment (never rendered inline) — same posture as the other binary/text
  # exports in this codebase (feed_controller.ex, calendar_controller.ex, …).
  # `safe_content_type/1` below constrains its return to `@content_type_pattern`
  # or a fixed fallback — sobelow can't see that from the call site.
  # sobelow_skip ["XSS.SendResp", "XSS.ContentType"]
  defp serve(conn, item, org_id) do
    fetch = if item.audience == :public, do: &Storage.fetch/1, else: &Storage.fetch_private/1

    case fetch.(item.storage_key) do
      {:ok, bytes} ->
        track_download(item, org_id)

        conn
        |> put_resp_content_type(safe_content_type(item.content_type))
        |> put_resp_header(
          "content-disposition",
          "attachment; filename=\"#{sanitize_filename(item.filename)}\""
        )
        |> put_resp_header("x-content-type-options", "nosniff")
        |> send_resp(200, bytes)

      {:error, _reason} ->
        send_resp(conn, 404, "Not found")
    end
  end

  # A content type outside the inline allowlist is not something this app will
  # serve inline at all — it falls through to the download path, which is the
  # safe posture and also what a player would want for a format it can't play
  # anyway. `bytes` is a stored blob and `safe_content_type/1` is redundant
  # after the allowlist check but kept for symmetry with `serve/3` — sobelow
  # can't see either from the call site.
  # sobelow_skip ["XSS.SendResp", "XSS.ContentType"]
  defp serve_stream(conn, item, org_id) do
    if MediaKind.inline_streamable?(item.content_type) do
      conn
      |> put_resp_content_type(safe_content_type(item.content_type))
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("accept-ranges", "bytes")
      |> send_range(item, parse_range(get_req_header(conn, "range")))
    else
      serve(conn, item, org_id)
    end
  end

  # No (or unusable) Range header: the whole representation with a 200, still
  # advertising `Accept-Ranges` so the player knows it may seek later.
  #
  # A 206 would be the memory-cheap answer but is not a legal reply to a
  # request that carried no `Range` (RFC 9110 §15.3.7), so the full body has
  # to go out — and reading it whole is exactly the allocation `@max_chunk`
  # exists to prevent. So it goes out **chunked**: one `@max_chunk` read at a
  # time, never more than that resident. The first read also reports the total,
  # so a blob that fits inside one chunk still gets a plain 200 with a
  # `Content-Length` (captions, short audio, every image and document) and only
  # genuinely large media pays the streamed response.
  defp send_range(conn, item, :none) do
    case fetch_range(item, 0, @max_chunk - 1) do
      {:ok, %{bytes: bytes, total: total}} when total <= @max_chunk ->
        send_whole(conn, bytes)

      {:ok, %{bytes: bytes, total: total}} ->
        conn
        |> send_chunked(200)
        |> stream_from(item, bytes, @max_chunk, total)

      # A zero-length blob is unsatisfiable as a *range* but is a perfectly
      # good representation: 200 with an empty body, not 404.
      {:error, {:range_not_satisfiable, 0}} ->
        send_whole(conn, "")

      # The adapter couldn't do a ranged read at all (`KilnCMS.Storage.S3`'s
      # `:no_content_range`, or a backend with no range support). Falling back
      # to a whole-blob read is the only way such a deployment can serve media
      # — and it must stay reachable, because the ranged branch above routes
      # its own unsupported-range error HERE. Without this the fallback would
      # 404 instead, and `/stream` would be dead on that backend.
      {:error, _reason} ->
        send_unranged(conn, item)
    end
  end

  defp send_range(conn, item, {:range, first, last}) do
    case fetch_range(item, first, clamp_last(first, last)) do
      {:ok, read} ->
        send_partial(conn, read)

      # RFC 9110 §14.4 requires the 416 carry the resource's real length —
      # `bytes */<total>`. `*` in the length position is not valid syntax, so
      # when the adapter couldn't tell us the total (S3's 416 carries no body
      # we parse) the header is omitted entirely rather than sent malformed.
      {:error, {:range_not_satisfiable, total}} when is_integer(total) ->
        conn
        |> put_resp_header("content-range", "bytes */#{total}")
        |> send_resp(416, "")

      {:error, :range_not_satisfiable} ->
        send_resp(conn, 416, "")

      # A storage backend that can't do ranges at all (see
      # `KilnCMS.Storage.S3`'s `:no_content_range`) still has to serve the
      # media. RFC 9110 allows ignoring a Range and answering 200 with the
      # full representation, which every player handles by simply not seeking.
      {:error, _reason} ->
        send_range(conn, item, :none)
    end
  end

  # Invalid/unsupported Range syntax falls back to the full representation
  # rather than erroring, which RFC 9110 explicitly allows and every player
  # copes with. Because that path is chunked, an unparseable `Range:` is not a
  # way to ask for an unbounded allocation.
  defp send_range(conn, item, :invalid), do: send_range(conn, item, :none)

  # sobelow_skip ["XSS.SendResp"]
  defp send_unranged(conn, item) do
    read = if item.audience == :public, do: &Storage.fetch/1, else: &Storage.fetch_private/1

    case read.(item.storage_key) do
      {:ok, bytes} -> send_resp(conn, 200, bytes)
      {:error, _reason} -> send_resp(conn, 404, "Not found")
    end
  end

  # sobelow_skip ["XSS.SendResp"]
  defp send_whole(conn, bytes), do: send_resp(conn, 200, bytes)

  # Writes `bytes`, then walks the rest of the blob a chunk at a time. A read
  # or write failure mid-stream can't be turned into an error status — the 200
  # is already on the wire — so it stops, and the client sees a short body,
  # which is the only signal HTTP leaves available at that point.
  defp stream_from(conn, item, bytes, offset, total) do
    case chunk(conn, bytes) do
      {:ok, conn} when offset >= total -> conn
      {:ok, conn} -> continue_stream(conn, item, offset, total)
      {:error, _reason} -> conn
    end
  end

  defp continue_stream(conn, item, offset, total) do
    case fetch_range(item, offset, offset + @max_chunk - 1) do
      {:ok, %{bytes: next}} -> stream_from(conn, item, next, offset + byte_size(next), total)
      {:error, _reason} -> conn
    end
  end

  # sobelow_skip ["XSS.SendResp"]
  defp send_partial(conn, %{bytes: bytes, first: first, last: last, total: total}) do
    conn
    |> put_resp_header("content-range", "bytes #{first}-#{last}/#{total}")
    |> send_resp(206, bytes)
  end

  defp fetch_range(item, first, last) do
    read =
      if item.audience == :public,
        do: &Storage.fetch_range/3,
        else: &Storage.fetch_private_range/3

    read.(item.storage_key, first, last)
  end

  # Enforce `@max_chunk` on the *request*, before any bytes are read, so a
  # `bytes=0-` on a huge file never allocates more than the cap.
  defp clamp_last(first, :eof), do: first + @max_chunk - 1
  defp clamp_last(first, last), do: min(last, first + @max_chunk - 1)

  # Single ranges only. A multi-range request (`bytes=0-99,200-299`) needs a
  # multipart/byteranges body no media player has ever asked for, so it is
  # treated as unsatisfiable syntax and answered with the whole
  # representation, which is a valid response to any Range request.
  @range_pattern ~r/\Abytes=(\d*)-(\d*)\z/
  defp parse_range([]), do: :none

  defp parse_range([value | _rest]) do
    case Regex.run(@range_pattern, String.trim(value)) do
      # `bytes=-500`: the last 500 bytes. Needs the total size to resolve, which
      # only the storage adapter knows, so it isn't supported — a media player
      # uses it rarely if ever, and the full-representation fallback is correct.
      [_all, "", _suffix] -> :invalid
      [_all, first, ""] -> {:range, String.to_integer(first), :eof}
      [_all, first, last] -> bounded_range(String.to_integer(first), String.to_integer(last))
      _ -> :invalid
    end
  end

  # A backwards range (`last` before `first`) is malformed, not unsatisfiable.
  defp bounded_range(first, last) when last >= first, do: {:range, first, last}
  defp bounded_range(_first, _last), do: :invalid

  # Best-effort, off the response body: a counter failure must never turn a
  # successful download into an error page. Inline rather than
  # `Task.Supervisor`-detached (`KilnCMSWeb.ViewTracking`'s pattern) — one
  # atomic UPDATE, not the multi-upsert cost a page view pays, so there's
  # nothing worth moving off the request path for.
  defp track_download(item, org_id) do
    CMS.increment_media_downloads(item, authorize?: false, tenant: org_id)
  rescue
    _ -> :ok
  end

  # `content_type` is normally byte-sniffed (ImageProcessor/DocumentProcessor
  # only ever write a fixed handful of values), but it's also in
  # `MediaItem.default_accept` — an editor with direct API/admin access could
  # set it to an arbitrary string, and that string would otherwise land
  # verbatim in a response header (`put_resp_content_type/2`). Only pass
  # through something that actually looks like a MIME type.
  @content_type_pattern ~r/\A[\w.+-]+\/[\w.+-]+\z/
  defp safe_content_type(content_type) when is_binary(content_type) do
    if Regex.match?(@content_type_pattern, content_type),
      do: content_type,
      else: "application/octet-stream"
  end

  defp safe_content_type(_), do: "application/octet-stream"

  # A stored filename could carry a `"` or CR/LF that would break out of the
  # quoted Content-Disposition parameter (the same header-injection shape as
  # #468's mail-subject fix) — strip control characters and escape quotes.
  defp sanitize_filename(nil), do: "download"

  defp sanitize_filename(filename) do
    filename
    |> String.replace(~r/[\r\n]+/, " ")
    |> String.replace("\"", "'")
  end
end
