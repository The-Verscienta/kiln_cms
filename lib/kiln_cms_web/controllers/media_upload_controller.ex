defmodule KilnCMSWeb.MediaUploadController do
  @moduledoc """
  The media upload API — creating `MediaItem`s over HTTP (docs/api.md →
  "Uploading media").

    * `POST /api/media` — multipart, one `file` plus optional metadata.
    * `POST /api/media/import-url` — JSON `{url, …}`, fetched server-side
      through `KilnCMS.SafeFetch`.
    * `POST /api/media/uploads` and `POST /api/media/uploads/complete` — the
      presigned direct-to-storage flow for large files
      (`KilnCMS.Media.DirectUpload`).

  Every route runs the media library's own pipeline, `KilnCMS.Media.Ingest`
  (via `KilnCMS.Media.Upload`), so an API upload is sniffed, size-capped,
  metadata-stripped, quarantined, derived and authorized exactly like one
  dropped on `/editor/media`. Editing an item afterwards is the JSON:API
  `PATCH /api/json/media-items/:id` (or GraphQL `updateMediaItem`), not a
  route here.

  ## Order of operations on `POST /api/media`

  The endpoint deliberately leaves this route's body unread
  (`KilnCMSWeb.Plugs.MultipartParser`), so the order is:

    1. the `:api` pipeline authenticates (JWT or `kiln_` API key);
    2. the `:media_upload` bucket rate-limits per client address;
    3. `authorize/2` below refuses anyone the create policy would — before a
       single body byte is read, so a read-only key or an anonymous caller
       cannot spool 500 MB to disk only to be told no;
    4. `parse_upload_body/2` parses the multipart body under the upload
       limit (`Ingest.max_upload_size/0` plus room for the form fields);
    5. `Ingest` applies the tighter per-kind cap once it has sniffed the kind.

  The create at the end of the pipeline re-runs the policy — step 3 is an
  early answer, not the authorization.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Media.{DirectUpload, Ingest, Upload}
  alias KilnCMSWeb.{ApiError, MediaUploadJSON, Params}

  # Form fields ride in the same body as the file; a megabyte is far more room
  # than alt text, a caption and a tag list can take.
  @form_overhead 1_000_000

  @upload_parsers Plug.Parsers.init(
                    parsers: [:multipart],
                    pass: ["*/*"],
                    length: Ingest.max_upload_size() + @form_overhead
                  )

  plug :authorize
  plug :parse_upload_body when action == :create

  @doc "`POST /api/media` — one multipart `file`, plus optional metadata fields."
  def create(conn, params) do
    with {:ok, %Plug.Upload{path: path, filename: filename}} <- upload(params),
         {:ok, filename} <- Upload.filename(filename),
         {:ok, metadata} <- Upload.metadata(params),
         {:ok, item} <- Upload.from_file(path, filename, metadata, actor(conn), org_id(conn)) do
      created(conn, item)
    else
      {:error, reason} -> refuse(conn, reason)
    end
  end

  @doc "`POST /api/media/import-url` — `{url, filename?, …metadata}`."
  def import_url(conn, params) do
    with {:ok, url} <- required_string(params, "url"),
         {:ok, filename} <- import_filename(params),
         {:ok, metadata} <- Upload.metadata(params),
         {:ok, item} <- Upload.from_url(url, filename, metadata, actor(conn), org_id(conn)) do
      created(conn, item)
    else
      {:error, reason} -> refuse(conn, reason)
    end
  end

  @doc "`POST /api/media/uploads` — `{filename, byte_size}` → a presigned upload URL."
  def begin_direct(conn, params) do
    case DirectUpload.begin(params, actor(conn), org_id(conn)) do
      {:ok, upload} -> conn |> put_status(:created) |> json(MediaUploadJSON.direct(upload))
      {:error, reason} -> refuse(conn, reason)
    end
  end

  @doc "`POST /api/media/uploads/complete` — `{token, …metadata}` → the media item."
  def complete_direct(conn, params) do
    with {:ok, token} <- required_string(params, "token"),
         {:ok, metadata} <- Upload.metadata(params),
         {:ok, item} <- DirectUpload.complete(token, metadata, actor(conn), org_id(conn)) do
      created(conn, item)
    else
      {:error, reason} -> refuse(conn, reason)
    end
  end

  # ── plugs ─────────────────────────────────────────────────────────────────

  defp authorize(conn, _opts) do
    case Upload.authorize(actor(conn), org_id(conn)) do
      :ok -> conn
      {:error, reason} -> conn |> refuse(reason) |> halt()
    end
  end

  # Runs only after `authorize/2` has let the request through — see the
  # moduledoc. A body over the limit raises `Plug.Parsers.RequestTooLargeError`,
  # which the JSON error view answers as a 413 in the usual envelope.
  defp parse_upload_body(conn, _opts), do: Plug.Parsers.call(conn, @upload_parsers)

  # ── helpers ───────────────────────────────────────────────────────────────

  defp actor(conn), do: Ash.PlugHelpers.get_actor(conn)
  defp org_id(conn), do: KilnCMSWeb.Tenant.current_org_id(conn)

  defp upload(%{"file" => %Plug.Upload{} = upload}), do: {:ok, upload}
  defp upload(_params), do: {:error, :missing_file}

  # Optional: absent means the name the URL's path implies.
  defp import_filename(params) do
    case Params.string(params, "filename") do
      nil -> {:ok, nil}
      name -> Upload.filename(name)
    end
  end

  defp required_string(params, key) do
    case Params.string(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid, key, "is required"}}
    end
  end

  defp created(conn, item) do
    item = Upload.load_for_response(item, actor(conn), org_id(conn))

    conn
    |> put_status(:created)
    |> put_resp_header("location", "/api/json/media-items/#{item.id}")
    |> json(MediaUploadJSON.show(item))
  end

  # ── refusals ──────────────────────────────────────────────────────────────

  defp refuse(conn, :unauthenticated),
    do: ApiError.send(conn, :unauthorized, "unauthorized", "Authentication required.")

  defp refuse(conn, :forbidden),
    do:
      ApiError.send(
        conn,
        :forbidden,
        "forbidden",
        "This credential may not upload media: it needs a read + write API key (or a JWT) on an editor or admin account."
      )

  defp refuse(conn, :missing_file),
    do: ApiError.send(conn, 422, "missing_file", "Send the file as the multipart field `file`.")

  defp refuse(conn, {:invalid, field, message}),
    do: ApiError.send(conn, 422, "invalid_parameter", "#{field} #{message}")

  defp refuse(conn, :too_large),
    do:
      ApiError.send(
        conn,
        413,
        "too_large",
        "The file is larger than this server accepts for its type."
      )

  defp refuse(conn, :encrypted),
    do:
      ApiError.send(
        conn,
        422,
        "encrypted",
        "The document is password-protected, so its metadata can't be removed. Upload an unlocked copy."
      )

  # Refused rather than stored with its metadata — the server can't strip
  # this kind of file (#807/#820), or couldn't strip this one.
  defp refuse(conn, reason) when reason in [:unavailable, :av_strip_unavailable],
    do:
      ApiError.send(
        conn,
        422,
        "strip_unavailable",
        "This server can't remove metadata from this kind of file, so it wasn't stored."
      )

  defp refuse(conn, :strip_failed),
    do:
      ApiError.send(
        conn,
        422,
        "strip_failed",
        "The file's metadata couldn't be removed, so it wasn't stored."
      )

  # The one refusal worth retrying (#1100).
  defp refuse(conn, :av_strip_no_space) do
    conn
    |> put_resp_header("retry-after", "60")
    |> ApiError.send(
      503,
      "insufficient_storage",
      "The server is out of temporary disk space to process this file. Try again shortly."
    )
  end

  defp refuse(conn, :storage_failed),
    do: ApiError.send(conn, 502, "storage_failed", "The file couldn't be stored. Try again.")

  # The site has its own object storage (#1559) and it can't be used right
  # now. Refused, never stored in the deployment's bucket instead
  # (`KilnCMS.Storage.SiteProfiles`); a site admin fixes it at
  # /editor/site-storage. No detail: a refused endpoint's reason can name the
  # address it resolved to, which is not an API caller's to learn.
  defp refuse(conn, {:site_storage, _reason}),
    do:
      ApiError.send(
        conn,
        503,
        "site_storage_unavailable",
        "This site's own object storage can't be used right now, so the file wasn't stored. " <>
          "A site admin can check it at /editor/site-storage."
      )

  defp refuse(conn, :create_failed),
    do:
      ApiError.send(
        conn,
        422,
        "create_failed",
        "The media item couldn't be saved. Check that every tag_ids entry names a tag on this site."
      )

  defp refuse(conn, {:unsafe_url, _reason}), do: unsafe_url(conn)

  defp refuse(conn, {:http_status, status}),
    do: ApiError.send(conn, 422, "fetch_failed", "The URL answered HTTP #{status}.")

  # `SafeFetch` reports its own refusals as strings. The detail is ours, not
  # the fetcher's: its messages name resolved addresses, and the address a
  # hostname resolved to is not the caller's to learn from this endpoint.
  defp refuse(conn, "blocked" <> _), do: unsafe_url(conn)

  defp refuse(conn, "response exceeded" <> _),
    do:
      ApiError.send(
        conn,
        413,
        "too_large",
        "The URL's response is larger than an import accepts (#{Upload.import_max_bytes()} bytes). " <>
          "Upload the file instead."
      )

  defp refuse(conn, message) when is_binary(message),
    do: ApiError.send(conn, 422, "fetch_failed", "The URL couldn't be fetched.")

  defp refuse(conn, :direct_uploads_unavailable),
    do:
      ApiError.send(
        conn,
        501,
        "direct_uploads_unavailable",
        "Direct uploads need S3 storage with a private bucket configured. Use POST /api/media instead."
      )

  defp refuse(conn, :invalid_token),
    do:
      ApiError.send(
        conn,
        422,
        "invalid_upload_token",
        "The upload token is invalid, expired, or was issued to a different credential."
      )

  defp refuse(conn, :not_uploaded),
    do:
      ApiError.send(
        conn,
        422,
        "not_uploaded",
        "Nothing was uploaded for this token (or it was already completed)."
      )

  defp refuse(conn, :size_mismatch),
    do:
      ApiError.send(
        conn,
        422,
        "size_mismatch",
        "The uploaded object's size doesn't match the byte_size the upload was issued for."
      )

  # What remains is a byte-sniffing refusal — the file is not a kind the
  # library takes (`:unsupported_format`, `:invalid_image`, `:zip_bomb`, …).
  defp refuse(conn, _reason),
    do:
      ApiError.send(
        conn,
        415,
        "unsupported_media_type",
        "Not a supported file. The library takes images, PDFs and office documents, " <>
          "video, audio and WebVTT captions."
      )

  defp unsafe_url(conn),
    do:
      ApiError.send(
        conn,
        422,
        "unsafe_url",
        "That URL can't be fetched: it must be a public http(s) address."
      )
end
