defmodule KilnCMSWeb.ScrollableCodeFocusTest do
  @moduledoc """
  A `<pre>` that scrolls sideways must take keyboard focus, or a keyboard
  user cannot read the end of a long line (#2164, axe's
  `scrollable-region-focusable`).

  Content code blocks get this from the renderer (`KilnCMS.CodeBlocks`, tested
  in `KilnCMS.CodeBlocksTest`). This guards the app's own templates: every
  `<pre>` start tag in `lib/**/*.{ex,heex}` whose classes include
  `overflow-x-auto` must carry `tabindex="0"` too (and, alongside it,
  `role="group"` and an `aria-label`). A `<pre>` that also wraps
  (`whitespace-pre-wrap`) never overflows, so it is exempt.

  The scan is lexical and reads each start tag up to its own closing `>`, so a
  tag split over several lines is read whole. It does not render, and
  templates outside this repo (plugins) are not covered.
  """
  use ExUnit.Case, async: true

  @globs ["lib/**/*.ex", "lib/**/*.heex"]

  test "every scrolling <pre> in lib/ takes focus and has a name" do
    offenders =
      for glob <- @globs,
          path <- Path.wildcard(glob),
          {line, tag} <- pre_tags(File.read!(path)),
          missing = missing(tag),
          missing != [] do
        "#{path}:#{line} missing #{Enum.join(missing, ", ")}"
      end

    assert offenders == [],
           "scrolling <pre> without keyboard focus:\n  " <> Enum.join(offenders, "\n  ")
  end

  # The scanner on its own, so a broken parser can't pass the guard by finding
  # nothing.
  describe "scanner" do
    test "reads a start tag split over several lines" do
      src = """
      <p>x</p>
      <pre
        id="a"
        class="overflow-x-auto p-4"
      >{@x}</pre>
      """

      assert [{2, tag}] = pre_tags(src)
      assert tag =~ "overflow-x-auto"
      assert missing(tag) == [~s(tabindex="0"), ~s(role="group"), "aria-label"]
    end

    test "does not stop at a > inside an attribute expression" do
      src =
        ~s(<pre :if={@n > 0} class="overflow-x-auto" tabindex="0" role="group" aria-label={@l}>)

      assert [{1, tag}] = pre_tags(src)
      assert missing(tag) == []
    end

    test "exempts a wrapping <pre> and one that doesn't scroll" do
      assert missing(~s(<pre class="overflow-x-auto whitespace-pre-wrap">)) == []
      assert missing(~s(<pre class="p-2">)) == []
    end

    test "does not read <prefix> or similar as a <pre>" do
      assert pre_tags("`/<prefix>/<slug>` <pre-x>") == []
    end

    test "finds the app's own scrolling <pre>s" do
      tags =
        for glob <- @globs,
            path <- Path.wildcard(glob),
            {_, tag} <- pre_tags(File.read!(path)),
            do: tag

      assert Enum.count(tags, &(&1 =~ "overflow-x-auto")) >= 8
    end
  end

  defp missing(tag) do
    if tag =~ "overflow-x-auto" and not (tag =~ "whitespace-pre-wrap") do
      [~s(tabindex="0"), ~s(role="group"), "aria-label"]
      |> Enum.reject(&String.contains?(tag, &1))
    else
      []
    end
  end

  # `{line, start_tag}` for every `<pre` followed by whitespace or `>`.
  defp pre_tags(src) do
    ~r/<pre(?=[\s>])/
    |> Regex.scan(src, return: :index)
    |> Enum.map(fn [{start, _}] ->
      rest = binary_part(src, start, byte_size(src) - start)
      line = src |> binary_part(0, start) |> String.split("\n") |> length()
      {line, start_tag(rest)}
    end)
  end

  # Up to the `>` that closes the tag: not one inside a quoted value or a
  # `{…}` expression.
  defp start_tag(rest), do: rest |> take_tag([], nil, 0) |> IO.iodata_to_binary()

  defp take_tag(<<>>, acc, _quote, _depth), do: Enum.reverse(acc)
  defp take_tag(<<">", _::binary>>, acc, nil, 0), do: Enum.reverse([">" | acc])

  defp take_tag(<<c::utf8, rest::binary>>, acc, quote, depth) do
    {quote, depth} =
      case {<<c::utf8>>, quote} do
        {q, nil} when q in [~s("), "'"] and depth == 0 -> {q, depth}
        {q, q} -> {nil, depth}
        {"{", nil} -> {nil, depth + 1}
        {"}", nil} -> {nil, max(depth - 1, 0)}
        _ -> {quote, depth}
      end

    take_tag(rest, [<<c::utf8>> | acc], quote, depth)
  end
end
