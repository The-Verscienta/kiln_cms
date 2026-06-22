defmodule KilnCMS.HTMLSanitizer do
  @moduledoc """
  Sanitizes CMS-authored HTML and media URLs before public rendering.
  """

  alias KilnCMS.HTMLSanitizer.RichText

  @image_schemes ~w(http https)

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
