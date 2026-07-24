defmodule KilnCMS.Slug.Lint do
  @moduledoc """
  Yoast-style advisory slug checks (#456) — pure signals the content editor
  renders as non-blocking hints under the slug field. Nothing here ever
  prevents a save; the findings are suggestions:

    * `:slug_long` — more than 75 characters or 6 hyphen segments; search
      engines and shared links favor short URLs
    * `:keyphrase_not_in_slug` — a focus keyphrase is set but its content
      words don't all appear in the slug (Yoast's "keyphrase in slug" check)
    * `:keyphrase_not_in_title` — the focus keyphrase's content words don't
      all appear in the title or SEO title

  Word comparisons run through `Slug.derive/1` on both sides, so stop words
  and punctuation never cause false mismatches.
  """

  alias KilnCMS.Slug

  @max_chars 75
  @max_words 6

  @type finding :: :slug_long | :keyphrase_not_in_slug | :keyphrase_not_in_title

  @doc """
  Advisory findings for the given fields (`:slug`, `:title`, `:seo_title`,
  `:seo_keywords` — all optional/nilable), in display order.
  """
  @spec lint(map()) :: [finding()]
  def lint(fields) do
    slug = to_string(fields[:slug] || "")
    keyphrase_words = fields[:seo_keywords] |> Slug.focus_keyphrase() |> words()

    []
    |> add(:slug_long, slug != "" and long?(slug))
    |> add(
      :keyphrase_not_in_slug,
      keyphrase_words != [] and slug != "" and not subset?(keyphrase_words, words(slug))
    )
    |> add(
      :keyphrase_not_in_title,
      keyphrase_words != [] and not subset?(keyphrase_words, title_words(fields))
    )
    |> Enum.reverse()
  end

  defp add(acc, finding, true), do: [finding | acc]
  defp add(acc, _finding, false), do: acc

  # Raw segment count (stop words in a slug count against it), plus a
  # character ceiling for pathological titles.
  defp long?(slug),
    do: String.length(slug) > @max_chars or length(String.split(slug, "-")) > @max_words

  # Content words: slugified with stop words stripped, so "Guide to the Kiln"
  # and "guide-kiln" compare equal.
  defp words(text), do: text |> Slug.derive() |> String.split("-", trim: true)

  defp title_words(fields) do
    words(to_string(fields[:title] || "")) ++ words(to_string(fields[:seo_title] || ""))
  end

  defp subset?(needles, haystack), do: Enum.all?(needles, &(&1 in haystack))
end
