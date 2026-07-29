defmodule KilnCMS.Seo.Checks.Keyphrase do
  @moduledoc """
  The focus keyphrase — the first comma-separated entry of `seo_keywords` — and
  where it does or doesn't appear.

  Wraps `KilnCMS.Slug.Lint` for the title and slug halves rather than
  reimplementing them: #476 says #456's slug linting is the slug-scoped slice
  of this analysis and must not diverge from it. `Slug.Lint` reports only
  failures, so applicability (`:n_a` when there is no keyphrase, or no slug
  yet) is decided here.

  **English-biased**, like everything routed through `KilnCMS.Slug.content_words/1`,
  which strips English stop words.
  """
  use Kiln.Advisory

  alias Kiln.Advisory.Body
  alias Kiln.Advisory.Context
  alias KilnCMS.Slug

  @density_min 0.5
  @density_max 2.5
  # Below this the denominator is too small for a percentage to mean anything.
  @density_floor_words 50

  @impl Kiln.Advisory
  def check(%Context{} = context) do
    keyphrase = Slug.focus_keyphrase(Context.field(context, :seo_keywords))
    words = Slug.content_words(keyphrase)
    lints = lints(context)

    [
      set(keyphrase),
      from_lint(lints, :keyphrase_not_in_title, :seo_keywords, words),
      in_slug(Context.field(context, :slug), lints, words),
      slug_length(Context.field(context, :slug), lints),
      in_description(Context.field(context, :seo_description), words),
      in_first_paragraph(context.body.first_paragraph, words),
      density(context.body, keyphrase)
    ]
  end

  defp lints(context) do
    MapSet.new(
      Slug.Lint.lint(%{
        slug: Context.field(context, :slug),
        title: Context.field(context, :title),
        seo_title: Context.field(context, :seo_title),
        seo_keywords: Context.field(context, :seo_keywords)
      })
    )
  end

  defp set(""), do: finding(:info, :keyphrase_missing, :seo_keywords)
  defp set(_keyphrase), do: :ok

  defp from_lint(_lints, _code, _field, []), do: :n_a

  defp from_lint(lints, code, field, _words) do
    if MapSet.member?(lints, code), do: finding(:warning, code, field), else: :ok
  end

  # `Slug.Lint` guards this on a non-empty slug too, so a blank slug produces no
  # lint — which must read as "nothing to judge", not a pass.
  defp in_slug("", _lints, _words), do: :n_a
  defp in_slug(_slug, lints, words), do: from_lint(lints, :keyphrase_not_in_slug, :slug, words)

  defp slug_length("", _lints), do: :n_a

  defp slug_length(_slug, lints) do
    if MapSet.member?(lints, :slug_long), do: finding(:warning, :slug_long, :slug), else: :ok
  end

  defp in_description(_description, []), do: :n_a
  defp in_description("", _words), do: :n_a

  defp in_description(description, words) do
    if Slug.subset?(words, Slug.content_words(description)),
      do: :ok,
      else: finding(:warning, :keyphrase_not_in_description, :seo_description)
  end

  defp in_first_paragraph(_paragraph, []), do: :n_a
  defp in_first_paragraph("", _words), do: :n_a

  defp in_first_paragraph(paragraph, words) do
    if Slug.subset?(words, Slug.content_words(paragraph)),
      do: :ok,
      else: finding(:warning, :keyphrase_not_in_first_paragraph)
  end

  defp density(_body, ""), do: :n_a
  defp density(%{word_count: count}, _keyphrase) when count < @density_floor_words, do: :n_a

  defp density(body, keyphrase) do
    value = ratio(body, keyphrase)
    args = %{density: Float.round(value, 2), min: @density_min, max: @density_max}

    cond do
      value < @density_min -> finding(:warning, :keyphrase_density_low, :seo_keywords, args)
      value > @density_max -> finding(:warning, :keyphrase_density_high, :seo_keywords, args)
      true -> :ok
    end
  end

  # Occurrences as a contiguous run of **whole words** against the body's
  # precomputed tokens. Not a substring scan: `:binary.matches(text, "art")`
  # also fires inside `part`, `start` and `heart`, which reported a
  # correctly-used keyphrase as keyword stuffing.
  defp ratio(%{word_count: 0}, _keyphrase), do: 0.0

  defp ratio(body, keyphrase) do
    case keyphrase |> Body.fold() |> Body.tokenize() do
      [] ->
        0.0

      needle ->
        body.folded_words
        |> Enum.chunk_every(length(needle), 1, :discard)
        |> Enum.count(&(&1 == needle))
        |> Kernel.*(100)
        |> Kernel./(body.word_count)
    end
  end
end
