defmodule KilnCMS.Slug do
  @moduledoc """
  URL slug generation shared by content and taxonomy.

  `slugify/1` is the mechanical transform: transliterate diacritics, downcase,
  drop punctuation, collapse whitespace/underscores to single hyphens.

  `derive/1` builds an SEO-style slug from a content title: `slugify/1` plus
  stripping common English stop words ("a", "the", "of", …) so titles like
  "A Guide to the Kiln" become "guide-kiln". If stripping would leave nothing
  (the title is only stop words), the unstripped slug is returned instead.
  """

  @stop_words ~w(a an the and or but nor of for to in on at by with from as into onto)

  @doc "Title → SEO slug with stop words stripped; \"\" when nothing usable remains."
  def derive(title) when is_binary(title) do
    slug = slugify(title)

    case slug |> String.split("-", trim: true) |> Enum.reject(&(&1 in @stop_words)) do
      [] -> slug
      words -> Enum.join(words, "-")
    end
  end

  def derive(_title), do: ""

  @doc "Plain slug transform (no stop-word stripping) — used for taxonomy names."
  def slugify(text) when is_binary(text) do
    text
    # NFD + strip combining marks transliterates "Café" → "Cafe" instead of
    # the accented letter vanishing entirely in the ASCII filter below.
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/u, "")
    |> String.replace(~r/[\s_-]+/, "-")
    |> String.trim("-")
  end

  def slugify(_text), do: ""
end
