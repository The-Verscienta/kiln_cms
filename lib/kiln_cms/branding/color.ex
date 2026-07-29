defmodule KilnCMS.Branding.Color do
  @moduledoc """
  Derives a complete, WCAG-AA-safe primary token set from a single brand colour
  (#48).

  A white-label operator picks one colour. The design system needs four values
  per theme — the fill (`--color-primary`), the ink that sits *on* the fill
  (`--color-primary-content`), and the accent-as-text ink (`--color-primary-ink`)
  — in both light and dark. This module computes all of them.

  ## Why this is server-side Elixir and not CSS

  `oklch(from var(--brand) …)` (relative colour syntax) would express the
  lightness moves elegantly, but it is only Baseline *newly available*
  (Chrome 119 / Safari 16.4 / Firefox 128) and a public CMS frontend inherits
  its visitors' browsers, not the operator's. Its failure mode is also
  catastrophic rather than graceful: an unparsed value makes the custom property
  invalid at computed-value time, so `bg-primary` renders transparent and
  buttons vanish.

  The decisive reason, though, is that **CSS has no contrast function**. Picking
  the ink requires measuring a WCAG ratio and branching on it; `contrast-color()`
  is Safari-only. In CSS you would be back to a fixed near-black ink — which is
  precisely the accessibility bug this module exists to prevent.

  ## Why the output is hex

  Work happens in OKLCH (perceptually sane lightness moves), but the emitted
  value is hex, so the colour whose contrast we measured is byte-for-byte the
  colour the browser paints — no ambiguity about browser gamut mapping.
  Downstream `color-mix(in oklab, var(--color-primary) 10%, transparent)` in
  `app.css` is indifferent to the input notation.

  ## The mid-lightness trap

  A brand at L ≈ 0.52–0.62 (medium teal, mid green) fails against *both* a
  near-black and a near-white ink. Ink selection alone cannot fix it, so
  `derive/1` also nudges the **fill** lightness outward until a pair clears the
  threshold. If nothing clears — essentially unreachable within the search
  band — it returns `:error` and the caller falls back to the stock ember theme
  rather than shipping a failing contrast pair.
  """

  require Logger

  # WCAG AA for normal text is 4.5:1. We target slightly above it: these inks
  # land on small button and badge labels, and the final value is quantised to
  # 8-bit hex, so the headroom absorbs rounding.
  @min_ratio 4.6

  # Candidate inks and surfaces, declared in OKLCH exactly as `assets/css/app.css`
  # declares them, so the two never drift. Converted to linear-light sRGB on use
  # (module attributes can't call local functions, and this runs once per org per
  # cache TTL, not per request).
  #
  # These MUST be linear-light when they reach `luminance/1`. Passing the sRGB
  # values straight through silently turns the near-black ink into a mid-gray,
  # which fails AA against the stock ember brand itself.
  @ink_dark_oklch {0.21, 0.012, 255}
  @ink_light_oklch {0.98, 0.0, 0}

  # `--color-base-100` / `--color-base-200` in each theme (app.css) — the
  # surfaces `--color-primary-ink` is read on.
  @light_surfaces_oklch [{1.0, 0.0, 0}, {0.985, 0.0015, 255}]
  @dark_surfaces_oklch [{0.21, 0.006, 255}, {0.25, 0.006, 255}]

  # Derived from the repo's own ember pair so the stock theme is unchanged:
  # light oklch(69% 0.21 44) -> dark oklch(76% 0.175 44).
  #   L: 0.69 + 0.07 = 0.76  (floor 0.70 keeps a dark brand usable on charcoal)
  #   C: 0.21 * 0.833 = 0.175
  @dark_lift 0.07
  @dark_l_floor 0.70
  @dark_l_ceil 0.90
  @dark_chroma_scale 0.833

  defstruct [
    :light_primary,
    :light_content,
    :light_ink,
    :dark_primary,
    :dark_content,
    :dark_ink
  ]

  @type t :: %__MODULE__{
          light_primary: String.t(),
          light_content: String.t(),
          light_ink: String.t(),
          dark_primary: String.t(),
          dark_content: String.t(),
          dark_ink: String.t()
        }

  @doc """
  Derive the light and dark token set from a `#rrggbb` brand colour.

  Returns `{:ok, %KilnCMS.Branding.Color{}}` with every value a hex string, or
  `:error` when no fill/ink pair in the search band clears AA (the caller should
  fall back to the stock theme).
  """
  @spec derive(String.t()) :: {:ok, t()} | :error
  def derive(hex) when is_binary(hex) do
    with {:ok, rgb} <- parse_hex(hex),
         {l, c, h} = to_oklch(rgb),
         {:ok, light_fill, light_content} <- solve_fill(l, c, h),
         {:ok, dark_fill, dark_content} <- solve_fill(dark_l(l), c * @dark_chroma_scale, h) do
      {:ok,
       %__MODULE__{
         light_primary: to_hex(light_fill),
         light_content: to_hex(light_content),
         light_ink: solve_ink(light_fill, light_surfaces(), :darken),
         dark_primary: to_hex(dark_fill),
         dark_content: to_hex(dark_content),
         dark_ink: solve_ink(dark_fill, dark_surfaces(), :lighten)
       }}
    else
      _ -> :error
    end
  end

  def derive(_), do: :error

  defp ink_candidates, do: [from_oklch(@ink_dark_oklch), from_oklch(@ink_light_oklch)]
  defp light_surfaces, do: Enum.map(@light_surfaces_oklch, &from_oklch/1)
  defp dark_surfaces, do: Enum.map(@dark_surfaces_oklch, &from_oklch/1)

  # OKLCH with hue in DEGREES (as app.css writes it) -> linear-light sRGB.
  defp from_oklch({l, c, h_deg}), do: to_linear_rgb({l, c, h_deg * :math.pi() / 180})

  defp dark_l(l) do
    (l + @dark_lift) |> max(@dark_l_floor) |> min(@dark_l_ceil)
  end

  # Find a fill close to the requested lightness whose best ink clears AA.
  #
  # Search the requested lightness first, then step outward in 0.02 increments.
  # Stepping the FILL (not just swapping the ink) is what rescues the
  # mid-lightness band, where neither a near-black nor a near-white ink works.
  defp solve_fill(l, c, h) do
    0.0
    |> then(&[&1 | Enum.flat_map(1..6, fn i -> [i * 0.02, -i * 0.02] end)])
    |> Enum.find_value(:error, fn delta ->
      fill = clamp_to_gamut((l + delta) |> max(0.0) |> min(1.0), c, h)

      case best_ink(fill) do
        {:ok, ink} -> {:ok, fill, ink}
        :error -> nil
      end
    end)
  end

  # Highest-contrast ink for a fill, provided it clears the threshold. Dark ink
  # is tried first so the stock ember brand keeps its hand-tuned near-black.
  defp best_ink(fill) do
    y = luminance(fill)

    ink_candidates()
    |> Enum.map(fn ink -> {ratio(y, luminance(ink)), ink} end)
    |> Enum.max_by(fn {r, _ink} -> r end)
    |> case do
      {r, ink} when r >= @min_ratio -> {:ok, ink}
      _ -> :error
    end
  end

  # `--color-primary-ink` is the brand used AS TEXT on a pale surface, so it is
  # solved against the surfaces rather than against the fill. app.css derives it
  # with a fixed `color-mix(… 68%, black)`, but that constant is tuned for ember
  # and does not clear AA for a very light brand — so we solve for it instead of
  # letting the CSS derivation carry it.
  defp solve_ink(fill, surfaces, direction) do
    {l, c, h} = to_oklch(fill)
    worst = Enum.map(surfaces, &luminance/1)

    0..40
    |> Enum.find_value(nil, &readable_ink(&1, {l, c, h}, worst, direction))
    |> case do
      nil ->
        # Unreachable in practice (pure black/white always clear against these
        # surfaces), but never emit an unreadable token.
        Logger.warning("brand ink solve exhausted; falling back to a plain #{direction} extreme")
        if direction == :darken, do: "#000000", else: "#ffffff"

      hex ->
        hex
    end
  end

  # One step of the ink search: nudge lightness in `direction` and keep the
  # candidate only if it clears the threshold against EVERY surface.
  defp readable_ink(step, {l, c, h}, surface_luminances, direction) do
    adjusted =
      case direction do
        :darken -> l - step * 0.02
        :lighten -> l + step * 0.02
      end

    with true <- adjusted >= 0.0 and adjusted <= 1.0,
         candidate = clamp_to_gamut(adjusted, c, h),
         y = luminance(candidate),
         true <- Enum.all?(surface_luminances, &(ratio(y, &1) >= @min_ratio)) do
      to_hex(candidate)
    else
      _ -> nil
    end
  end

  ## Colour space conversions

  defp parse_hex("#" <> <<r::binary-2, g::binary-2, b::binary-2>>) do
    with {r, ""} <- Integer.parse(r, 16),
         {g, ""} <- Integer.parse(g, 16),
         {b, ""} <- Integer.parse(b, 16) do
      {:ok, {srgb_to_linear(r), srgb_to_linear(g), srgb_to_linear(b)}}
    else
      _ -> :error
    end
  end

  defp parse_hex(_), do: :error

  defp srgb_to_linear(byte) do
    c = byte / 255

    if c <= 0.04045, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
  end

  defp linear_to_srgb(c) do
    c = c |> max(0.0) |> min(1.0)
    v = if c <= 0.0031308, do: c * 12.92, else: 1.055 * :math.pow(c, 1 / 2.4) - 0.055

    round(v * 255)
  end

  # Linear sRGB -> OKLab -> OKLCH (Björn Ottosson's matrices).
  defp to_oklch({r, g, b}) do
    l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)

    lab_l = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
    lab_a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
    lab_b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s

    {lab_l, :math.sqrt(lab_a * lab_a + lab_b * lab_b), :math.atan2(lab_b, lab_a)}
  end

  defp to_linear_rgb({l, c, h}) do
    lab_a = c * :math.cos(h)
    lab_b = c * :math.sin(h)

    l_ = l + 0.3963377774 * lab_a + 0.2158037573 * lab_b
    m_ = l - 0.1055613458 * lab_a - 0.0638541728 * lab_b
    s_ = l - 0.0894841775 * lab_a - 1.2914855480 * lab_b

    l3 = l_ * l_ * l_
    m3 = m_ * m_ * m_
    s3 = s_ * s_ * s_

    {4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
     -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
     -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3}
  end

  defp cbrt(x) when x < 0, do: -:math.pow(-x, 1 / 3)
  defp cbrt(x), do: :math.pow(x, 1 / 3)

  # Binary-search chroma down until the colour is representable in sRGB, so the
  # colour we measure contrast against is the colour the browser paints.
  defp clamp_to_gamut(l, c, h) do
    rgb = to_linear_rgb({l, c, h})

    if in_gamut?(rgb), do: rgb, else: search_chroma(l, 0.0, c, h, 16)
  end

  defp search_chroma(l, lo, _hi, h, 0), do: to_linear_rgb({l, lo, h})

  defp search_chroma(l, lo, hi, h, steps) do
    mid = (lo + hi) / 2

    if in_gamut?(to_linear_rgb({l, mid, h})),
      do: search_chroma(l, mid, hi, h, steps - 1),
      else: search_chroma(l, lo, mid, h, steps - 1)
  end

  defp in_gamut?({r, g, b}) do
    Enum.all?([r, g, b], &(&1 >= -0.0001 and &1 <= 1.0001))
  end

  ## WCAG contrast

  # Relative luminance, computed on the same linear values the conversions use.
  defp luminance({r, g, b}) do
    0.2126 * clamp01(r) + 0.7152 * clamp01(g) + 0.0722 * clamp01(b)
  end

  defp clamp01(c), do: c |> max(0.0) |> min(1.0)

  defp ratio(y1, y2), do: (max(y1, y2) + 0.05) / (min(y1, y2) + 0.05)

  @doc """
  The WCAG 2.1 contrast ratio between two `#rrggbb` colours. Exposed for the
  test suite, which pins the derived pairs against AA.
  """
  @spec contrast(String.t(), String.t()) :: float()
  def contrast(hex_a, hex_b) do
    with {:ok, a} <- parse_hex(hex_a), {:ok, b} <- parse_hex(hex_b) do
      ratio(luminance(a), luminance(b))
    else
      _ -> 0.0
    end
  end

  defp to_hex({r, g, b}) do
    "#" <>
      ([linear_to_srgb(r), linear_to_srgb(g), linear_to_srgb(b)]
       |> Enum.map_join(&(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0")))
       |> String.downcase())
  end
end
