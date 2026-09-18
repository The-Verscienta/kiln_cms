defmodule KilnCMSWeb.ComponentKitClassesTest do
  @moduledoc """
  The component kit in `assets/css/app.css` borrows DaisyUI's *names* without
  the dependency, so a DaisyUI class the kit never defined — `btn-error`,
  `badge-success`, `link`, `input-sm` — compiles, renders, and styles nothing.
  On a `.btn` that leaves a transparent box that reads as plain text; on an
  `<a>` or `<input>`, Tailwind's preflight has already stripped the underline
  or border. Nothing else fails when that happens, so this does.

  Hyphenated names (`badge-success`) are rare enough outside CSS to match in
  any string literal, which also catches classes returned from helpers. A bare
  base name (`link`, `badge`) is an ordinary word, so it only counts inside a
  `class` attribute.
  """
  use ExUnit.Case, async: true

  @bases ~w(alert avatar badge breadcrumbs btn card carousel chat checkbox collapse
            countdown diff divider dock drawer dropdown fieldset file-input filter footer
            indicator input join kbd label link list loading mask menu modal navbar
            pagination progress radial-progress radio range rating select skeleton stack
            stat stats steps swap tab tabs table textarea timeline toast toggle tooltip
            validator form-control)

  @modifiers ~w(xs sm md lg xl primary secondary accent neutral info success warning error
                ghost outline soft dash link active disabled bordered item row title body
                actions box text group vertical horizontal col-grow hover spinner dots ring
                ball bars infinity start end top bottom center open close lifted boxed zebra
                pin wide square circle)

  @hyphenated Regex.compile!("^(#{Enum.join(@bases, "|")})-(#{Enum.join(@modifiers, "|")})$")

  test "every DaisyUI-named class in the web layer is one the kit defines" do
    kit =
      ~r/\.([a-z][a-z0-9-]*)/
      |> Regex.scan(File.read!("assets/css/app.css"), capture: :all_but_first)
      |> MapSet.new(&hd/1)

    undefined =
      for path <- Path.wildcard("lib/kiln_cms_web/**/*.{ex,heex}"),
          source = File.read!(path),
          {token, line} <- daisy_tokens(source),
          token not in kit,
          do: "#{path}:#{line}  #{token}"

    assert undefined == [], """
    These classes are not in the component kit (assets/css/app.css), so they
    style nothing. Use the kit's name (btn-danger, btn-sm, field-input, the
    <.badge> component …) or add the rule to the kit and docs/design-language.md.

    #{Enum.join(undefined, "\n")}
    """
  end

  test "the scan sees a helper's class string and a bare name in a class attribute" do
    source = ~S'''
    defp tone(:ok), do: "badge-success"
    <a class="link text-sm">x</a>
    <span class={["px-2", @on && "badge"]}>y</span>
    <p role="alert" phx-click="toggle">z</p>
    '''

    assert daisy_tokens(source) == [{"badge-success", 1}, {"link", 2}, {"badge", 3}]
  end

  defp daisy_tokens(source) do
    anywhere =
      for {string, offset} <- string_literals(source, 0),
          token <- String.split(string),
          Regex.match?(@hyphenated, token),
          do: {token, offset}

    in_class =
      for {string, offset} <- class_strings(source),
          token <- String.split(string),
          token in @bases,
          do: {token, offset}

    (anywhere ++ in_class)
    |> Enum.uniq()
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map(fn {token, offset} -> {token, line_of(source, offset)} end)
  end

  # `class="…"` values, and every string literal inside a `class={…}` expression.
  defp class_strings(source) do
    static =
      for [{start, len}] <- Regex.scan(~r/(?<![\w-])class="[^"]*"/, source, return: :index),
          do: {binary_part(source, start + 7, len - 8), start}

    dynamic =
      for [{start, len}] <- Regex.scan(~r/(?<![\w-])class=\{/, source, return: :index),
          expr = balanced(source, start + len - 1),
          lit <- string_literals(expr, start + len - 1),
          do: lit

    static ++ dynamic
  end

  defp string_literals(text, base) do
    for [{start, len}] <- Regex.scan(~r/"(?:[^"\\\n]|\\.)*"/, text, return: :index),
        do: {binary_part(text, start + 1, len - 2), base + start}
  end

  # The `{…}` expression opening at `at`, braces balanced.
  defp balanced(source, at) do
    source
    |> binary_part(at, byte_size(source) - at)
    |> String.graphemes()
    |> Enum.reduce_while({0, []}, fn
      "{", {depth, acc} -> {:cont, {depth + 1, ["{" | acc]}}
      "}", {1, acc} -> {:halt, {0, acc}}
      "}", {depth, acc} -> {:cont, {depth - 1, ["}" | acc]}}
      char, {depth, acc} -> {:cont, {depth, [char | acc]}}
    end)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.join()
  end

  defp line_of(source, offset),
    do: source |> binary_part(0, offset) |> String.split("\n") |> length()
end
