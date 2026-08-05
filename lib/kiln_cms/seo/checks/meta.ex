defmodule KilnCMS.Seo.Checks.Meta do
  @moduledoc """
  The fields that become `<title>`, `<meta name="description">` and
  `og:image`: are they present, and are they the length a search result shows?

  Length bounds are read from config at check time, not baked in as module
  attributes — `KilnCMS.Seo.Draft.normalize/1`, the prompt and the suggestion
  card's counter all read them at runtime, and an operator who raises
  `title_max` should not get a card reading "70/75" contradicted by a warning
  that 70 is over 60.
  """
  use Kiln.Advisory

  alias Kiln.Advisory.Context

  # Search-only: a title tag's length says nothing about whether the page is
  # usable with a screen reader.
  @impl Kiln.Advisory
  def lenses, do: [:seo]

  @title_min 30
  @description_min 70

  @impl Kiln.Advisory
  def check(%Context{} = context) do
    [
      title(Context.field(context, :seo_title), Context.field(context, :title)),
      description(Context.field(context, :seo_description)),
      og_image(Context.field(context, :seo_image))
    ]
  end

  # A blank SEO title is only advisory: delivery falls back to `title`.
  defp title("", ""), do: :n_a
  defp title("", _title), do: finding(:info, :seo_title_missing, :seo_title)

  defp title(seo_title, title) do
    length = String.length(seo_title)
    max = KilnCMS.Seo.title_max()

    cond do
      length < @title_min -> too_short(:seo_title_short, :seo_title, length, @title_min, max)
      length > max -> too_long(:seo_title_long, :seo_title, length, max)
      same?(seo_title, title) -> finding(:info, :seo_title_duplicates_title, :seo_title)
      true -> :ok
    end
  end

  defp description(""), do: finding(:warning, :seo_description_missing, :seo_description)

  defp description(description) do
    length = String.length(description)
    max = KilnCMS.Seo.description_max()

    cond do
      length < @description_min ->
        too_short(:seo_description_short, :seo_description, length, @description_min, max)

      length > max ->
        too_long(:seo_description_long, :seo_description, length, max)

      true ->
        :ok
    end
  end

  # Delivery emits `og:image` from `seo_image` alone — `ContentController`'s
  # `render_content_body/6` does **not** fall back to the featured image — so a
  # featured image does not satisfy this. Saying otherwise would promise a
  # social preview that never ships.
  defp og_image(""), do: finding(:info, :og_image_missing, :seo_image)
  defp og_image(_value), do: :ok

  defp too_short(code, field, length, min, max),
    do: finding(:warning, code, field, %{length: length, min: min, max: max})

  defp too_long(code, field, length, max),
    do: finding(:warning, code, field, %{length: length, max: max})

  defp same?(a, b), do: String.downcase(a) == String.downcase(b)
end
