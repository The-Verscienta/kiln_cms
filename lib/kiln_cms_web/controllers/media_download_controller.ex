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
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.CMS
  alias KilnCMS.Storage

  def show(conn, %{"id" => id}) do
    actor = conn.assigns[:current_user]
    org_id = KilnCMSWeb.Tenant.current_org_id(conn)

    case CMS.get_media_item(id, actor: actor, tenant: org_id) do
      {:ok, item} -> serve(conn, item, org_id)
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
