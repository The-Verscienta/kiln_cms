defmodule KilnCMS.Social.Composer do
  @moduledoc """
  Turns a published document into the text of an announcement (#497).

  Default shape is `title` + blank line + canonical URL, with the excerpt
  slotted in when it fits. A rule can override it with a `template` carrying
  `{{title}}`, `{{excerpt}}`, `{{url}}` and `{{type}}` — the same
  double-brace interpolation `KilnCMS.Automation.RuleWorker`'s `send_email`
  reaction already uses, so an operator learns one syntax.

  ## Truncation is length-aware, and the URL survives it

  The provider's limit is a hard cap (300 characters on Bluesky, 500 on a
  default Mastodon), so something has to give on a long title. What gives is
  never the URL: an announcement that has been truncated into a link-less
  sentence is strictly worse than no announcement, because it looks like a
  post someone meant to write.

  So the URL is reserved out of the budget first, then the rest is trimmed to
  fit with an ellipsis — on a **grapheme** boundary, not a byte one, so a
  multibyte character is not cut in half into invalid UTF-8 that the provider
  rejects with an opaque 400.

  ## Nothing here trusts the document

  Titles and excerpts are author-supplied and end up on a public timeline, so
  the text is normalized: control characters out, runs of whitespace collapsed.
  Not an injection defence — a plain-text post has no syntax to inject into —
  but a title carrying a stray newline run would otherwise post as something
  the editor did not see in the editor.
  """

  @ellipsis "…"

  @doc """
  Compose the announcement text for `record` at `url`, within `max_length`.

  `template` is optional; `nil` uses the default shape.
  """
  @spec compose(struct(), String.t(), pos_integer(), String.t() | nil) :: String.t()
  def compose(record, url, max_length, template \\ nil) do
    title = clean(Map.get(record, :title))
    excerpt = clean(Map.get(record, :excerpt) || Map.get(record, :seo_description))
    type = record |> KilnCMS.Firing.Engine.public_type() |> to_string()

    case template do
      nil -> default_text(title, excerpt, url, max_length)
      "" -> default_text(title, excerpt, url, max_length)
      raw -> rendered_text(raw, title, excerpt, type, url, max_length)
    end
  end

  # Title, then the excerpt if there is room for a useful amount of it, then the
  # URL. The excerpt is dropped whole rather than shaved to a word or two: three
  # words of trailing context read as a truncation bug, not as a summary.
  @min_excerpt 40

  defp default_text(title, excerpt, url, max_length) do
    budget = max_length - String.length(url) - 2

    head =
      case excerpt do
        nil ->
          truncate(title, budget)

        excerpt ->
          with_excerpt = title <> "\n\n" <> excerpt

          if String.length(with_excerpt) <= budget or
               budget - String.length(title) - 2 >= @min_excerpt,
             do: truncate(with_excerpt, budget),
             else: truncate(title, budget)
      end

    head <> "\n\n" <> url
  end

  # A template is rendered first and truncated after, because the operator chose
  # where the URL goes and moving it would be a surprise. If their layout does
  # not fit, the tail is what is lost — including, if they put it last, the URL.
  # That is their call to make; the default shape is the one that protects it.
  defp rendered_text(template, title, excerpt, type, url, max_length) do
    template
    |> String.replace("{{title}}", title || "")
    |> String.replace("{{excerpt}}", excerpt || "")
    |> String.replace("{{type}}", type)
    |> String.replace("{{url}}", url)
    |> clean()
    |> Kernel.||("")
    |> truncate(max_length)
  end

  @doc """
  Trim `text` to `limit` characters, ending with an ellipsis when it had to cut.

  Counts graphemes, so an emoji or an accented character is never split into
  invalid UTF-8 — which providers reject with an unhelpful 400.
  """
  @spec truncate(String.t(), integer()) :: String.t()
  def truncate(text, limit) when limit <= 0, do: String.slice(text || "", 0, 0)

  def truncate(text, limit) do
    if String.length(text) <= limit do
      text
    else
      text |> String.slice(0, max(limit - 1, 0)) |> String.trim_trailing() |> Kernel.<>(@ellipsis)
    end
  end

  # Control characters (except the newlines a template may legitimately use) out,
  # runs of blank lines and spaces collapsed, ends trimmed.
  defp clean(nil), do: nil

  defp clean(text) when is_binary(text) do
    cleaned =
      text
      |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, "")
      |> String.replace(~r/\r\n?/u, "\n")
      |> String.replace(~r/\n{3,}/u, "\n\n")
      |> String.replace(~r/[ \t]{2,}/u, " ")
      |> String.trim()

    if cleaned == "", do: nil, else: cleaned
  end

  defp clean(_), do: nil
end
