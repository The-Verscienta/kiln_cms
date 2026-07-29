defmodule KilnCMS.Branding.ColorTest do
  @moduledoc """
  The derived brand token sets must clear WCAG AA — that is the entire reason
  this module exists rather than emitting the operator's colour verbatim.

  The expectations here are deliberately **pinned**: a later "optimization" of
  the OKLCH math that quietly stopped clearing contrast would otherwise leave
  the suite green. See the mid-lightness cases in particular — those are the
  ones that fail against both a near-black and a near-white ink and are only
  rescued by nudging the fill.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Branding.Color

  # WCAG AA for normal text. The module targets 4.6 for hex-quantisation
  # headroom; assert the standard so the headroom can be retuned freely.
  @aa 4.5

  # base-100 in each theme — the surface `--color-primary-ink` is read on.
  @light_surface "#ffffff"
  @dark_surface "#1e2024"

  describe "derive/1" do
    test "reproduces the stock ember tokens, so an unchanged design system stays unchanged" do
      assert {:ok, color} = Color.derive("#ff6200")

      # The brand itself is in gamut and readable as-is: emitted verbatim.
      assert color.light_primary == "#ff6200"

      # app.css declares the dark primary as oklch(76% 0.175 44) — i.e. the
      # light L lifted by 0.07 and the chroma scaled by 0.833. If this drifts,
      # the derivation has stopped matching the hand-tuned design system.
      assert color.dark_primary == "#ff8e61"
    end

    test "returns hex, never a CSS function, so the measured colour is the painted colour" do
      assert {:ok, color} = Color.derive("#0f62fe")

      for value <- Map.values(Map.from_struct(color)) do
        assert value =~ ~r/\A#[0-9a-f]{6}\z/
      end
    end

    test "rejects anything that is not a 6-digit hex" do
      for bad <- ["", "red", "#fff", "#12345", "oklch(55% 0.2 264)", nil, 123] do
        assert Color.derive(bad) == :error
      end
    end
  end

  describe "accessibility of the derived pairs" do
    # A spread covering the hostile shapes: the extremes, a fully saturated
    # primary, the mid-lightness danger band that fails against BOTH inks, a
    # near-white and a near-black brand, and a neutral gray.
    @adversarial [
      "#000000",
      "#ffffff",
      "#ff6200",
      "#0f62fe",
      "#00ff00",
      "#3f8f8f",
      "#808080",
      "#1a1a2e",
      "#fff8dc",
      "#ffd700"
    ]

    test "button ink clears AA on the fill, in both themes" do
      for hex <- @adversarial do
        assert {:ok, color} = Color.derive(hex), "#{hex} produced no token set at all"

        light = Color.contrast(color.light_primary, color.light_content)
        dark = Color.contrast(color.dark_primary, color.dark_content)

        assert light >= @aa, "#{hex}: light button ink is only #{Float.round(light, 2)}:1"
        assert dark >= @aa, "#{hex}: dark button ink is only #{Float.round(dark, 2)}:1"
      end
    end

    test "accent-as-text ink clears AA on the page surface, in both themes" do
      for hex <- @adversarial do
        assert {:ok, color} = Color.derive(hex)

        light = Color.contrast(color.light_ink, @light_surface)
        dark = Color.contrast(color.dark_ink, @dark_surface)

        assert light >= @aa, "#{hex}: light text ink is only #{Float.round(light, 2)}:1"
        assert dark >= @aa, "#{hex}: dark text ink is only #{Float.round(dark, 2)}:1"
      end
    end

    test "every hue at every lightness produces an accessible pair" do
      # Broad sweep rather than a handful of samples: a regression that only
      # breaks one corner of the colour wheel should still fail the suite.
      for hue <- 0..330//30, lightness <- 10..90//10 do
        hex = hsl_to_hex(hue, 0.7, lightness / 100)

        assert {:ok, color} = Color.derive(hex), "#{hex} (hue #{hue}) produced no token set"

        assert Color.contrast(color.light_primary, color.light_content) >= @aa,
               "#{hex} (hue #{hue}, L #{lightness}) fails AA in light mode"

        assert Color.contrast(color.dark_primary, color.dark_content) >= @aa,
               "#{hex} (hue #{hue}, L #{lightness}) fails AA in dark mode"
      end
    end
  end

  describe "contrast/2" do
    test "matches the known WCAG extremes" do
      assert_in_delta Color.contrast("#000000", "#ffffff"), 21.0, 0.01
      assert_in_delta Color.contrast("#ffffff", "#ffffff"), 1.0, 0.01
    end

    test "is symmetric" do
      assert Color.contrast("#ff6200", "#ffffff") == Color.contrast("#ffffff", "#ff6200")
    end
  end

  # Minimal HSL->hex, only for generating the sweep above.
  defp hsl_to_hex(h, s, l) do
    c = (1 - abs(2 * l - 1)) * s
    x = c * (1 - abs(:math.fmod(h / 60, 2) - 1))
    m = l - c / 2

    {r, g, b} =
      cond do
        h < 60 -> {c, x, 0}
        h < 120 -> {x, c, 0}
        h < 180 -> {0, c, x}
        h < 240 -> {0, x, c}
        h < 300 -> {x, 0, c}
        true -> {c, 0, x}
      end

    [r, g, b]
    |> Enum.map_join(fn v ->
      ((v + m) * 255)
      |> round()
      |> max(0)
      |> min(255)
      |> Integer.to_string(16)
      |> String.pad_leading(2, "0")
    end)
    |> then(&("#" <> String.downcase(&1)))
  end
end
