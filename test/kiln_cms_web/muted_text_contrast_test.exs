defmodule KilnCMSWeb.MutedTextContrastTest do
  @moduledoc """
  Muted text is `text-base-content` at reduced opacity, and nothing renders
  wrong when the opacity is too low, so this test is what notices (#2163).

  Measured against the tokens in `assets/css/app.css`, `/50` and `/60` miss
  WCAG 1.4.3's 4.5:1 for body text on the light theme (3.09, 4.12) and `/50`
  misses it on the dark theme's raised surfaces. `/70` is the floor: it clears
  4.5:1 on every surface in both themes.

  Three halves:

    1. the contrast math, computed from the css tokens (oklch to sRGB, alpha
       blend in sRGB like a browser), pinned to the measured table;
    2. a lexical scan of `lib/kiln_cms_web/**/*.{ex,heex}` for muted text
       classes below the floor. Public paths (`@public`) must be at zero; the
       console is a ratchet against `muted_text_console_baseline.txt`, which
       may only go down;
    3. a self-test of the scanner on fixture strings.

  The guard is lexical (class names), not rendered: it does not run axe, and
  templates authored outside this repo (plugins) are not covered. A legitimate
  non-text use (an icon glyph, a disabled control) carries a `contrast-ok:`
  comment on the same line or the line above, saying why.

  After lowering a console count, regenerate the baseline with
  `KILN_UPDATE_CONTRAST_BASELINE=1 mix test test/kiln_cms_web/muted_text_contrast_test.exs`.
  """
  use ExUnit.Case, async: true

  @marker "contrast-ok"
  @floor 70
  @min_ratio 4.5
  @css "assets/css/app.css"
  @baseline "test/kiln_cms_web/muted_text_console_baseline.txt"

  # Anything rendered to anonymous readers: every controller template and the
  # live modules that mount Layouts.public/auth/app before sign-in (token
  # previews, setup wizard, public forms, memberships, auth screens). Shared
  # components used publicly (core/block components) are kept at zero by hand
  # and by the ratchet; their console-only leftovers are in the baseline.
  @public_globs [
    "lib/kiln_cms_web/controllers/**/*.{ex,heex}",
    "lib/kiln_cms_web/components/block_components.ex",
    "lib/kiln_cms_web/live/{release_preview,setup,form,preview,token_preview,membership,confirm,reset,magic_sign_in,sign_in,sign_out}_live.ex",
    "lib/kiln_cms_web/live/auth_*.ex"
  ]

  describe "contrast math" do
    setup do
      %{themes: themes()}
    end

    test "pins the measured table", %{themes: t} do
      pin = fn theme, step, surface, expected ->
        assert_in_delta ratio(t, theme, step, surface), expected, 0.05
      end

      pin.(:light, 50, :base_100, 3.09)
      pin.(:light, 60, :base_100, 4.12)
      pin.(:light, 65, :base_300, 4.41)
      pin.(:light, 70, :base_100, 5.64)
      pin.(:light, 70, :base_200, 5.53)
      pin.(:light, 70, :base_300, 5.10)
      pin.(:dark, 50, :base_100, 4.69)
      pin.(:dark, 50, :base_200, 4.51)
      pin.(:dark, 50, :base_300, 4.16)
    end

    test "the floor clears 4.5:1 on every surface in both themes", %{themes: t} do
      for theme <- [:light, :dark],
          surface <- [:base_100, :base_200, :base_300, {:base_200, 40}, {:base_200, 60}] do
        r = ratio(t, theme, @floor, surface)

        assert r >= @min_ratio,
               "text-base-content/#{@floor} on #{inspect(surface)} (#{theme}): #{r}"
      end
    end

    test "the steps below the floor are what the scan forbids", %{themes: t} do
      # /50 and /60 each fail somewhere; if this stops holding the floor is stale.
      for step <- [50, 60] do
        assert Enum.any?(
                 for theme <- [:light, :dark], s <- [:base_100, :base_200, :base_300] do
                   ratio(t, theme, step, s) < @min_ratio
                 end
               )
      end
    end
  end

  describe "text classes" do
    test "public paths have no muted text below the floor" do
      offenders =
        for path <- public_paths(),
            {line, token} <- offending(File.read!(path)),
            do: "#{path}:#{line}  #{token}"

      assert offenders == [], """
      Muted text below text-base-content/#{@floor} fails WCAG AA (4.5:1) on at
      least one surface. Use `text-base-content/#{@floor}`. For a non-text use
      (icon glyph, disabled control) add a `#{@marker}: <why>` comment on the
      same line or the line above.

      #{Enum.join(offenders, "\n")}
      """
    end

    test "the console never gains muted text below the floor" do
      baseline = read_baseline()
      counts = console_counts()

      if System.get_env("KILN_UPDATE_CONTRAST_BASELINE") == "1" do
        body = for {path, n} <- Enum.sort(counts), do: "#{path} #{n}\n"
        File.write!(@baseline, body)
      else
        grew =
          for {path, n} <- counts, n > Map.get(baseline, path, 0) do
            "#{path}: #{n} (baseline #{Map.get(baseline, path, 0)})"
          end

        assert grew == [], """
        These console files gained text classes below text-base-content/#{@floor}.
        Use /#{@floor}, or mark a non-text use with `#{@marker}:`. The baseline
        only goes down (#{@baseline}).

        #{Enum.join(grew, "\n")}
        """
      end
    end

    test "the scan flags low-opacity text and honours the allowlist comment" do
      source = ~S'''
      <p class="text-base-content/50">a</p>
      <p class="text-base-content/70 text-base-content/90">b</p>
      <p class="border-base-content/10 bg-base-content/5 ring-base-content/20 divide-base-content/10">c</p>
      <p class="dark:text-base-content/40 hover:text-base-content/65">d</p>
      <p class="text-base-content/[0.55] text-base-content/[0.8]">e</p>
      <%!-- contrast-ok: glyph --%>
      <.icon class="text-base-content/30" />
      <.icon class="text-base-content/30" /> <%!-- contrast-ok: glyph --%>
      <hr />
      <p class="opacity-60">f</p>
      <p class="opacity-70 opacity-100 opacity-0 hover:opacity-50 disabled:opacity-40">g</p>
      <p class="text-base-content/25 text-base-content/5">h</p>
      <p class="x-text-base-content/40 bg-opacity-50 fill-opacity-40">i</p>
      '''

      assert offending(source) == [
               {1, "text-base-content/50"},
               {4, "dark:text-base-content/40"},
               {4, "hover:text-base-content/65"},
               {5, "text-base-content/[0.55]"},
               {10, "opacity-60"},
               {12, "text-base-content/25"},
               {12, "text-base-content/5"}
             ]
    end
  end

  # -- scan ---------------------------------------------------------------

  @text_class ~r/(?<![\w-])((?:[\w-]+:)*)text-base-content\/(?:(\d+)|\[([\d.]+)%?\])/
  @opacity_class ~r/(?<![\w:-])opacity-(\d+)(?![\w-])/

  # [{line, token}] for each class below the floor, minus marked lines.
  defp offending(source) do
    lines = String.split(source, "\n")

    for {line, index} <- Enum.with_index(lines),
        not String.contains?(line, @marker),
        not (index > 0 and String.contains?(Enum.at(lines, index - 1), @marker)),
        token <- low_tokens(line),
        do: {index + 1, token}
  end

  defp low_tokens(line) do
    text =
      for [whole, _prefix, num | rest] <- Regex.scan(@text_class, line),
          below_floor?(num, List.first(rest, "")),
          do: whole

    opacity =
      for [whole, n] <- Regex.scan(@opacity_class, line),
          String.to_integer(n) in 1..(@floor - 1)//1,
          do: whole

    text ++ opacity
  end

  defp below_floor?("", arb), do: percent(arb) < @floor
  defp below_floor?(num, _), do: String.to_integer(num) < @floor

  defp percent(arb) do
    {value, _} = Float.parse(arb)
    if String.contains?(arb, ".") and value <= 1.0, do: value * 100, else: value
  end

  defp public_paths do
    @public_globs |> Enum.flat_map(&Path.wildcard/1) |> Enum.uniq() |> Enum.sort()
  end

  defp console_counts do
    public = MapSet.new(public_paths())

    for path <- Path.wildcard("lib/kiln_cms_web/**/*.{ex,heex}"),
        not MapSet.member?(public, path),
        n = path |> File.read!() |> offending() |> length(),
        n > 0,
        into: %{},
        do: {path, n}
  end

  defp read_baseline do
    for line <- File.read!(@baseline) |> String.split("\n", trim: true), into: %{} do
      [path, n] = String.split(line, " ")
      {path, String.to_integer(n)}
    end
  end

  # -- contrast math ------------------------------------------------------

  # `{r, g, b}` 0..255 for `--color-base-*` per theme, parsed from app.css.
  # The first declaration of each token is the light `@theme`, the second the
  # `[data-theme="dark"]` block.
  defp themes do
    css = File.read!(@css)

    parse = fn name ->
      ~r/--color-#{name}:\s*oklch\(([\d.]+)%\s+([\d.]+)\s+([\d.]+)\)/
      |> Regex.scan(css)
      |> Enum.map(fn [_, l, c, h] -> oklch_to_srgb(num(l), num(c), num(h)) end)
    end

    tokens = for name <- ~w(base-100 base-200 base-300 base-content), do: {name, parse.(name)}

    for {name, [light, dark]} <- tokens, reduce: %{light: %{}, dark: %{}} do
      acc ->
        key = name |> String.replace("-", "_") |> String.to_atom()
        acc |> put_in([:light, key], light) |> put_in([:dark, key], dark)
    end
  end

  defp num(s), do: elem(Float.parse(s), 0)

  # Contrast of `text-base-content/step` on a surface: `:base_100`, `:base_200`,
  # `:base_300`, or `{:base_200, alpha}` (a `bg-base-200/alpha` tint over base-100).
  defp ratio(themes, theme, step, surface) do
    t = Map.fetch!(themes, theme)

    bg =
      case surface do
        {token, alpha} -> blend(Map.fetch!(t, token), t.base_100, alpha / 100)
        token -> Map.fetch!(t, token)
      end

    fg = blend(t.base_content, bg, step / 100)
    contrast(fg, bg)
  end

  # Source-over in encoded sRGB, rounded to 8 bits as a browser paints it.
  defp blend({r1, g1, b1}, {r2, g2, b2}, a) do
    mix = fn f, b -> round(a * f + (1 - a) * b) end
    {mix.(r1, r2), mix.(g1, g2), mix.(b1, b2)}
  end

  defp contrast(a, b) do
    [hi, lo] = Enum.sort([luminance(a), luminance(b)], :desc)
    (hi + 0.05) / (lo + 0.05)
  end

  defp luminance({r, g, b}) do
    lin = fn c ->
      c = c / 255
      if c <= 0.04045, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
    end

    0.2126 * lin.(r) + 0.7152 * lin.(g) + 0.0722 * lin.(b)
  end

  defp oklch_to_srgb(l_pct, c, h_deg) do
    l = l_pct / 100
    h = h_deg * :math.pi() / 180
    a = c * :math.cos(h)
    b = c * :math.sin(h)

    l_ = :math.pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
    m_ = :math.pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
    s_ = :math.pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)

    r = 4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_
    g = -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_
    bl = -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_

    {encode(r), encode(g), encode(bl)}
  end

  defp encode(c) do
    c = c |> max(0.0) |> min(1.0)
    v = if c <= 0.0031308, do: 12.92 * c, else: 1.055 * :math.pow(c, 1 / 2.4) - 0.055
    round(v * 255)
  end
end
