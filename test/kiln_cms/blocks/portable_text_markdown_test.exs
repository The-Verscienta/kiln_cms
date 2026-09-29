defmodule KilnCMS.Blocks.PortableTextMarkdownTest do
  @moduledoc """
  Portable Text → Markdown (`KilnCMS.Blocks.PortableText.to_markdown/1`), and
  its contract with `KilnCMS.Markdown`: what it writes parses back to the same
  prose.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Blocks.PortableText
  alias KilnCMS.Markdown

  # Markdown → Portable Text, through the converter the editor uses.
  defp body(markdown) do
    [%{"type" => "rich_text", "value" => %{"body" => body}}] = Markdown.to_blocks(markdown)
    body
  end

  defp round_trips?(markdown) do
    original = body(markdown)

    PortableText.to_html(body(PortableText.to_markdown(original))) ==
      PortableText.to_html(original)
  end

  test "styles, lists, marks, code, tables and rules survive a round trip" do
    assert round_trips?("""
           ## Heading with `code`

           Para **bold *both*** and [a link](https://x.com/a_b), ~~gone~~, <u>under</u>.

           - a
               - nested **b**
           - c

           1. one
           2. two

           > quoted *text*

           ```elixir
           def x, do: "```"
           ```

           | h1 | h2 |
           |---|---|
           | 1 \\| x | 2 |

           ---
           """)
  end

  test "text that looks like Markdown stays text" do
    for text <- ["2 * 3 * 4", "# not a heading", "- not a list", "1. not a list", "[x](y)"] do
      pt = [%{"style" => "normal", "children" => [%{"text" => text}]}]
      assert PortableText.to_plain_text(body(PortableText.to_markdown(pt))) == text
    end
  end

  test "an underscore inside a word is not escaped" do
    pt = [%{"style" => "normal", "children" => [%{"text" => "snake_case_name"}]}]
    assert PortableText.to_markdown(pt) == "snake_case_name"
  end

  test "whitespace at a marked span's edge moves outside its delimiters" do
    pt = [
      %{
        "style" => "normal",
        "children" => [
          %{"text" => "a"},
          %{"text" => " bold ", "marks" => ["strong"]},
          %{"text" => "b"}
        ]
      }
    ]

    assert PortableText.to_markdown(pt) == "a **bold** b"
  end

  test "a numbered list after a bullet list starts at one, a blank line apart" do
    pt = [
      %{"listItem" => "bullet", "level" => 1, "children" => [%{"text" => "x"}]},
      %{"listItem" => "number", "level" => 1, "children" => [%{"text" => "y"}]}
    ]

    assert PortableText.to_markdown(pt) == "- x\n\n1. y"
  end

  test "an unknown mark key and a malformed body are ignored" do
    pt = [%{"style" => "normal", "children" => [%{"text" => "x", "marks" => ["nope"]}]}]
    assert PortableText.to_markdown(pt) == "x"
    assert PortableText.to_markdown(nil) == ""
    assert PortableText.to_markdown(["junk"]) == ""
  end
end
