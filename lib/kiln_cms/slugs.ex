defmodule KilnCMS.Slugs do
  @moduledoc """
  Slug helpers shared by the authoring surfaces.

  `slugify/1` turns a human label (a title or taxonomy name) into a URL-safe
  slug: lowercase, ASCII-ish, words joined by single hyphens. It's the same
  transform the editor's "auto slug from title" and the taxonomy quick-create use,
  so a slug previewed while typing matches what gets stored.
  """

  @doc """
  Convert `text` to a lowercase, hyphen-joined slug. Returns `""` for blank or
  punctuation-only input.

      iex> KilnCMS.Slugs.slugify("Hello, World!")
      "hello-world"
      iex> KilnCMS.Slugs.slugify("  Trailing — Dashes  ")
      "trailing-dashes"
  """
  @spec slugify(String.t() | nil) :: String.t()
  def slugify(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/u, "")
    |> String.replace(~r/[\s_-]+/, "-")
    |> String.trim("-")
  end
end
