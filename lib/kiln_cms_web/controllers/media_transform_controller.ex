defmodule KilnCMSWeb.MediaTransformController do
  @moduledoc """
  Serves on-the-fly image transforms: `GET /media/:id/t/:ops`.

  The grammar, the signing and allowlist rules and the geometry are
  `KilnCMS.Media.ImageTransform`; the cache and the render are
  `KilnCMS.Media.Derivatives`. This module orders the checks so the cheap ones
  refuse first:

    1. **parse** the `<ops>` segment — 400 on anything malformed;
    2. **authorize the parameters** — a valid signature, or an allowlisted
       unsigned request (400 off-list, 403 bad signature or unsigned
       disabled). No database or storage work has happened yet;
    3. **read the item** through `MediaDownloadController.readable_item/2`,
       the same policy-checked read `/media/:id/download` makes — 404 for
       missing, denied and quarantined alike;
    4. **plan** — 422 for something that isn't a transformable image, or a
       source over the pixel cap;
    5. answer `If-None-Match` with a 304 from the plan alone;
    6. serve the cached derivative, or — within the per-client `:media_render`
       budget (429) and the node's render gate (503 when saturated) — render
       it.

  ## Cache headers

  A public item's transform is the same bytes for every viewer, so it is
  `public`. It is `immutable` for a year only when the URL's `v` matches the
  item's current `ImageTransform.version/1` — that is the only case where
  this URL can never serve different pixels. Without `v`, or with a stale one,
  the current image is served for five minutes. An item outside the `:public`
  audience is `private, no-store`, like its download. `fm_auto` adds
  `Vary: Accept`.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Media.{Derivatives, ImageTransform}
  alias KilnCMSWeb.{MediaDownloadController, RateLimit}

  @immutable "public, max-age=31536000, immutable"
  @unpinned "public, max-age=300"
  @private "private, no-store"

  def show(conn, %{"id" => id, "ops" => ops}) do
    with {:ok, params} <- ImageTransform.parse(ops),
         :ok <- ImageTransform.authorize(id, params),
         {:ok, item} <- readable(conn, id),
         {:ok, plan} <- ImageTransform.plan(item, params, accept(conn)) do
      conn = put_image_headers(conn, item, params, plan)

      if fresh?(conn, plan),
        do: send_resp(conn, 304, ""),
        else: serve(conn, item, plan)
    else
      {:error, status, message} -> refuse(conn, status, message)
    end
  end

  defp readable(conn, id) do
    case MediaDownloadController.readable_item(conn, id) do
      {:ok, item} -> {:ok, item}
      :not_found -> {:error, :not_found, "Not found."}
    end
  end

  defp serve(conn, item, plan) do
    case Derivatives.lookup(item, plan) do
      {:ok, bytes} -> send_image(conn, "hit", bytes)
      :miss -> render_miss(conn, item, plan)
    end
  end

  defp render_miss(conn, item, plan) do
    case RateLimit.check(:media_render, RateLimit.client_key(conn.remote_ip)) do
      :allow ->
        case Derivatives.render(item, plan) do
          {:ok, bytes} ->
            send_image(conn, "miss", bytes)

          {:error, :busy} ->
            conn
            |> put_resp_header("retry-after", "2")
            |> refuse(:service_unavailable, "Busy rendering images. Try again shortly.")

          {:error, _reason} ->
            refuse(conn, :unprocessable, "This image could not be transformed.")
        end

      {:deny, retry_after_ms} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(max(1, div(retry_after_ms, 1000))))
        |> refuse(:too_many_requests, "Too many new image transforms. Try again shortly.")
    end
  end

  # `plan.content_type` comes from `ImageTransform`'s fixed format table
  # (image/jpeg, png, webp, avif) — never from the request or the stored row,
  # which sobelow can't see from here.
  # sobelow_skip ["XSS.ContentType"]
  defp put_image_headers(conn, item, params, plan) do
    conn
    |> put_resp_content_type(plan.content_type, nil)
    |> put_resp_header("cache-control", cache_control(item, params))
    |> put_resp_header("etag", etag(plan))
    |> put_resp_header("x-content-type-options", "nosniff")
    |> then(fn conn ->
      if plan.vary_accept?, do: put_resp_header(conn, "vary", "Accept"), else: conn
    end)
  end

  defp cache_control(%{audience: audience}, _params) when audience != :public, do: @private

  defp cache_control(item, %{v: v}) when is_binary(v) do
    if v == ImageTransform.version(item), do: @immutable, else: @unpinned
  end

  defp cache_control(_item, _params), do: @unpinned

  # The cache key already names the exact bytes (source, crop, size, format,
  # quality), so it is a strong validator as it stands.
  defp etag(plan), do: ~s("#{plan.cache_key}")

  defp fresh?(conn, plan) do
    tag = etag(plan)

    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.any?(fn candidate -> String.trim(candidate) in [tag, "W/" <> tag, "*"] end)
  end

  defp accept(conn), do: conn |> get_req_header("accept") |> Enum.join(",")

  # `bytes` is an image this app just encoded (or read back from its own
  # derivative key) with a content type from a fixed set — never request data.
  # sobelow_skip ["XSS.SendResp"]
  defp send_image(conn, cache, bytes) do
    conn
    |> put_resp_header("x-kiln-transform", cache)
    |> send_resp(200, bytes)
  end

  @statuses %{
    bad_request: 400,
    forbidden: 403,
    not_found: 404,
    unprocessable: 422,
    too_many_requests: 429,
    service_unavailable: 503
  }

  # Refusals are plain text and uncached: they are cheap to recompute, and a
  # cached 404 would outlive the item it was about. A parse error can quote a
  # fragment of the request path back, which `text/plain` + `nosniff` keeps
  # inert — sobelow can't see the content type from the call site.
  # sobelow_skip ["XSS.SendResp"]
  defp refuse(conn, status, message) do
    conn
    |> delete_resp_header("etag")
    |> delete_resp_header("vary")
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_content_type("text/plain")
    |> send_resp(Map.fetch!(@statuses, status), message)
  end
end
