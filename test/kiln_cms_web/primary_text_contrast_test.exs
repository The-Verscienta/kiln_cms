defmodule KilnCMSWeb.PrimaryTextContrastTest do
  @moduledoc """
  Ember (`--color-primary`, `#FF6200`) is a FILL colour: as text on the light
  theme's white surface it measures 3.00:1 (2.68:1 on a `bg-primary/10` tint),
  under WCAG 1.4.3's 4.5:1 for body text. The kit's `text-primary-ink` is the
  ink for an accent used as text (7.28:1 on white; see the ink tokens in
  `assets/css/app.css`). Nothing renders wrong when a link picks up
  `text-primary` instead, so this test is what notices (#1677).

  A legitimate non-text use — an icon glyph, a chart bar filled through
  `currentColor` — carries a `contrast-ok:` comment on the same line or the
  line above, saying why.
  """
  use ExUnit.Case, async: true

  @marker "contrast-ok"

  test "no text in the web layer is inked with raw text-primary" do
    offenders =
      for path <- Path.wildcard("lib/kiln_cms_web/**/*.{ex,heex}"),
          line <- offending_lines(File.read!(path)),
          do: "#{path}:#{line}"

    assert offenders == [], """
    `text-primary` is ~3:1 on white — below AA for text. Use `text-primary-ink`
    for links, chips, tabs and labels. If this is an icon or another graphic,
    say so with a `#{@marker}: <why>` comment on the line above.

    #{Enum.join(offenders, "\n")}
    """
  end

  test "the scan flags raw text-primary and honours the allowlist comment" do
    source = ~S'''
    <.link class="text-primary hover:underline">a</.link>
    <span class="text-primary-ink">b</span>
    <span class="text-primary-content bg-primary">c</span>
    <%!-- contrast-ok: icon --%>
    <.icon name="hero-x" class="text-primary" />
    <b class={[@on && "hover:text-primary"]}>d</b>
    <i class="text-primary/60">e</i>
    <u class="text-primary"><%!-- contrast-ok: glyph --%></u>
    '''

    assert offending_lines(source) == [1, 6, 7]
  end

  defp offending_lines(source) do
    lines = String.split(source, "\n")

    for {line, index} <- Enum.with_index(lines),
        Regex.match?(~r/(?<![\w-])text-primary(?![\w-])/, line),
        not String.contains?(line, @marker),
        not (index > 0 and String.contains?(Enum.at(lines, index - 1), @marker)),
        do: index + 1
  end
end
