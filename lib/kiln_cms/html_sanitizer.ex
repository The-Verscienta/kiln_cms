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
  Returns a safe embed iframe `src` for supported providers (YouTube, Vimeo),
  or `nil` when the URL is rejected.
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
      %{"v" => id} when is_binary(id) and id != "" ->
        "https://www.youtube.com/embed/" <> id

      _ ->
        case uri.path do
          "/embed/" <> id when id != "" -> "https://www.youtube.com/embed/" <> id
          _ -> nil
        end
    end
  end

  defp to_embed_src(%URI{path: "/" <> id}, "youtu.be") when id != "" do
    "https://www.youtube.com/embed/" <> id
  end

  defp to_embed_src(%URI{path: "/video/" <> id}, "player.vimeo.com") when id != "" do
    "https://player.vimeo.com/video/" <> id
  end

  defp to_embed_src(%URI{path: "/" <> id}, "vimeo.com") when id != "" do
    "https://player.vimeo.com/video/" <> id
  end

  defp to_embed_src(_, _), do: nil

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
