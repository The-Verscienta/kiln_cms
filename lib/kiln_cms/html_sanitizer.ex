defmodule KilnCMS.HTMLSanitizer do
  @moduledoc """
  Sanitizes CMS-authored HTML and media URLs before public rendering.
  """

  alias KilnCMS.HTMLSanitizer.RichText

  @image_schemes ~w(http https)

  @embed_hosts ~w(
    www.youtube.com
    youtube.com
    youtu.be
    player.vimeo.com
    vimeo.com
  )

  @doc """
  Strips unsafe markup from rich-text block HTML while preserving TipTap output.
  """
  def sanitize_rich_text(nil), do: ""
  def sanitize_rich_text(""), do: ""

  def sanitize_rich_text(html) when is_binary(html) do
    RichText.sanitize(html)
  end

  @doc """
  Sanitizes rich-text HTML and returns a `Phoenix.HTML` safe struct for HEEx.
  """
  def rich_text_raw(nil), do: {:safe, ""}
  def rich_text_raw(""), do: {:safe, ""}

  # sobelow_skip ["XSS.Raw"]
  def rich_text_raw(html) when is_binary(html) do
    html |> sanitize_rich_text() |> Phoenix.HTML.raw()
  end

  @doc """
  Returns a safe image `src` for block rendering, or `nil` when the URL is
  rejected (e.g. `javascript:`, `data:`, or path traversal).
  """
  def safe_image_src(nil), do: nil
  def safe_image_src(""), do: nil

  def safe_image_src(url) when is_binary(url) do
    url = String.trim(url)

    cond do
      safe_relative_path?(url) -> url
      safe_absolute_url?(url) -> url
      true -> nil
    end
  end

  defp safe_relative_path?(url) do
    String.starts_with?(url, "/") and
      not String.starts_with?(url, "//") and
      not String.contains?(url, "..")
  end

  @doc """
  Returns a safe link `href` for block rendering, or `nil` when the URL uses a
  disallowed scheme (`javascript:`, `data:`, `vbscript:`, …).

  Allowed: same-origin relative paths, `http(s)://`, and `mailto:`. Mirrors the
  URL policy applied on the public HEEx delivery path so fired `:web` artifacts
  consumed via `innerHTML` cannot carry scriptable links.
  """
  def safe_href(nil), do: nil
  def safe_href(""), do: nil

  def safe_href(url) when is_binary(url) do
    trimmed = String.trim(url)

    cond do
      safe_relative_path?(trimmed) -> trimmed
      safe_absolute_url?(trimmed) -> trimmed
      mailto?(trimmed) -> trimmed
      true -> nil
    end
  end

  def safe_href(_), do: nil

  defp mailto?(url) do
    case URI.parse(url) do
      %URI{scheme: "mailto"} -> not String.contains?(String.downcase(url), "javascript:")
      _ -> false
    end
  end

  @doc """
  Returns an absolute `http(s)` URL, or `nil`.

  Stricter than `safe_href/1`, which also allows relative paths and `mailto:`.
  For a value that names an *external resource* rather than a link an author
  typed — an embed's target, a webhook endpoint — neither of those is
  meaningful, and accepting them means storing something no consumer can use.
  """
  @spec safe_external_url(term()) :: String.t() | nil
  def safe_external_url(url) when is_binary(url) do
    trimmed = String.trim(url)
    if safe_absolute_url?(trimmed), do: trimmed, else: nil
  end

  def safe_external_url(_url), do: nil

  @doc """
  Returns a safe embed iframe `src` for the two framed providers (YouTube,
  Vimeo), or `nil` when the URL is not one of them.

  ## This is a render-time question, not a storage filter

  It answers "may this URL be put in an `<iframe>`?", and the answer is no for
  every host but two. It used to be applied on the *write* path as well, which
  meant a stored embed URL was either a canonical player URL or the empty
  string — every other URL an author pasted was silently destroyed on save.

  That made oEmbed cards (#489) impossible: by the time anything looked at a
  stored embed URL there was nothing left to resolve. Storage now keeps what
  the author typed (`safe_external_url/1`), and this decides — at render, on
  both surfaces — whether it gets a frame or a card.
  """
  def safe_embed_url(nil), do: nil
  def safe_embed_url(""), do: nil

  def safe_embed_url(url) when is_binary(url) do
    url = String.trim(url)

    with %URI{} = uri <- URI.parse(url),
         host when host in @embed_hosts <- uri.host,
         embed when is_binary(embed) <- to_embed_src(uri, host) do
      embed
    else
      _ -> nil
    end
  end

  @doc "Hosts allowed in Content-Security-Policy `frame-src` for embed blocks."
  def embed_csp_hosts, do: ~w(https://www.youtube.com https://player.vimeo.com)

  defp to_embed_src(%URI{query: query} = uri, host)
       when host in ["www.youtube.com", "youtube.com"] do
    case URI.decode_query(query || "") do
      %{"v" => id} ->
        youtube(id)

      _ ->
        case uri.path do
          "/embed/" <> id -> youtube(id)
          _ -> nil
        end
    end
  end

  defp to_embed_src(%URI{path: "/" <> id}, "youtu.be"), do: youtube(id)
  defp to_embed_src(%URI{path: "/video/" <> id}, "player.vimeo.com"), do: vimeo(id)
  defp to_embed_src(%URI{path: "/" <> id}, "vimeo.com"), do: vimeo(id)
  defp to_embed_src(_, _), do: nil

  # The id is concatenated into a URL these functions promise is safe, so it is
  # checked against the provider's own id shape rather than passed through.
  # Every render path escapes the result, so this is not the last line of
  # defence — but "the id is whatever was in the path" makes that escaping the
  # *only* line, and a video id is a well-known character set.
  defp youtube(id), do: if(id =~ ~r/\A[\w-]{1,64}\z/, do: "https://www.youtube.com/embed/" <> id)
  defp vimeo(id), do: if(id =~ ~r/\A\d{1,20}\z/, do: "https://player.vimeo.com/video/" <> id)

  defp safe_absolute_url?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in @image_schemes and is_binary(host) and host != "" ->
        not String.contains?(String.downcase(url), "javascript:")

      _ ->
        false
    end
  end
end
