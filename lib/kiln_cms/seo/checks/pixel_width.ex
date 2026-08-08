defmodule KilnCMS.Seo.Checks.PixelWidth do
  @moduledoc """
  Estimated rendered width of the title and description, in pixels (#551).

  Google truncates a SERP entry on **rendered width**, not on character count,
  so `WWWWWWWWWW` and `iiiiiiiiii` cut at very different lengths. This is what
  Yoast's bar actually measures, and it is why a title can pass a character
  count and still be clipped.

  ## Secondary to the character count, deliberately

  `KilnCMS.Seo.Checks.Meta` still reports characters and still owns the
  `:warning`. This check reports `:info`, because a pixel estimate from a width
  table is a *model* of a font Google can change without telling anyone, and a
  model should not outrank the plain measurement in an editor's list of things
  to fix. The two agree on the overwhelming majority of real titles; where they
  disagree, this is the one that is guessing.

  ## Latin scripts only

  The table below is per-Latin-character. For CJK it is meaningless — a CJK
  glyph is roughly one em regardless — and for Arabic or Devanagari, shaping
  makes per-character summing wrong in a different way. So the check is gated
  on `Kiln.Advisory.Context.english?/1`, the same gate the readability check
  uses, and answers `:n_a` elsewhere rather than reporting a confident number
  it has no basis for.

  That is a real limit, not a rounding error: it means this check is silent on
  most of the world's content, and #551 says so.

  ## Where the numbers come from

  Widths are for Arial ~20px, which is what desktop SERP titles have rendered
  in for years, normalised so a lowercase `n` is 10. They are bucketed rather
  than per-glyph: the difference between `m` and `w` is real, the difference
  between `b` and `d` is not worth a 200-entry table that would still be wrong
  the next time the font changes.
  """
  use Kiln.Advisory

  alias Kiln.Advisory.Context

  @impl Kiln.Advisory
  def lenses, do: [:seo]

  # Google's own cutoffs, in the same normalised units as the table below
  # (600px and 960px at ~20px Arial, scaled by the /10-per-`n` normalisation).
  @title_max 600
  @description_max 960

  # Bucketed Latin widths. Anything unlisted — punctuation, accented letters,
  # a stray emoji — falls back to `@default`, which is a lowercase average
  # rather than zero: an unknown glyph that measured as nothing would make a
  # title of them read as empty.
  @narrow ~c"ijltIf.,;:!|'`()[]{}/\\ "
  @wide ~c"mwMW@%"
  @caps ~c"ABCDEFGHKLNOPQRSTUVXYZ0123456789"
  @narrow_width 5
  @default 10
  @caps_width 12
  @wide_width 16

  @impl Kiln.Advisory
  def check(%Context{} = context) do
    if Context.english?(context) do
      [
        width(title(context), @title_max, :seo_title, :seo_title_wide),
        width(
          Context.field(context, :seo_description),
          @description_max,
          :seo_description,
          :seo_description_wide
        )
      ]
    else
      [:n_a, :n_a]
    end
  end

  # The title Google actually renders: `seo_title` when set, else the document
  # title — the same fallback delivery uses.
  defp title(context) do
    case Context.field(context, :seo_title) do
      "" -> Context.field(context, :title)
      seo_title -> seo_title
    end
  end

  defp width("", _max, _field, _code), do: :n_a

  defp width(text, max, field, code) do
    pixels = estimate(text)

    if pixels > max,
      do: finding(:info, code, field, %{pixels: pixels, max: max}),
      else: :ok
  end

  @doc """
  Estimated rendered width of `text`, in the normalised units above.

  Public because it is the part worth testing directly: the check around it is
  a threshold comparison, and the interesting behaviour is that `WWWW` and
  `iiii` come out far apart.
  """
  @spec estimate(String.t()) :: non_neg_integer()
  def estimate(text) when is_binary(text) do
    text
    |> String.to_charlist()
    |> Enum.reduce(0, fn char, total -> total + char_width(char) end)
  end

  defp char_width(char) do
    cond do
      char in @narrow -> @narrow_width
      char in @wide -> @wide_width
      char in @caps -> @caps_width
      true -> @default
    end
  end
end
