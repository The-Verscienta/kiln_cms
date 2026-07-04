defmodule ShowcaseWeb.BlocksTest do
  @moduledoc "Rendering KilnCMS typed blocks to HTML (pure — no network)."
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  defp render(blocks), do: render_component(&ShowcaseWeb.Blocks.content/1, blocks: blocks)

  test "renders a heading at the right level" do
    html = render([%{"_type" => "heading", "text" => "Chapter One", "level" => 2}])
    assert html =~ "<h2>Chapter One</h2>"
  end

  test "renders rich_text paragraphs with strong + link marks" do
    blocks = [
      %{
        "_type" => "rich_text",
        "body" => [
          %{
            "_type" => "block",
            "style" => "normal",
            "markDefs" => [%{"_key" => "k1", "_type" => "link", "href" => "https://example.com"}],
            "children" => [
              %{"_type" => "span", "text" => "Hello ", "marks" => []},
              %{"_type" => "span", "text" => "bold", "marks" => ["strong"]},
              %{"_type" => "span", "text" => " and a link", "marks" => ["k1"]}
            ]
          }
        ]
      }
    ]

    html = render(blocks)
    assert html =~ "<p>"
    assert html =~ "Hello"
    assert html =~ "<strong>"
    assert html =~ "bold"
    assert html =~ ~s(href="https://example.com")
  end

  test "renders an image with alt + caption" do
    html =
      render([
        %{"_type" => "image", "url" => "/pic.png", "alt" => "A pic", "caption" => "Fig 1"}
      ])

    assert html =~ ~s(src="/pic.png")
    assert html =~ ~s(alt="A pic")
    assert html =~ "Fig 1"
  end

  test "renders quote and divider" do
    html =
      render([
        %{"_type" => "quote", "text" => "To be", "citation" => "W.S."},
        %{"_type" => "divider"}
      ])

    assert html =~ "<blockquote>"
    assert html =~ "To be"
    assert html =~ "W.S."
    assert html =~ "<hr"
  end

  test "escapes text content (no raw HTML injection)" do
    html = render([%{"_type" => "heading", "text" => "<script>x</script>", "level" => 3}])
    refute html =~ "<script>x</script>"
    assert html =~ "&lt;script&gt;"
  end

  test "skips unknown block types gracefully" do
    html = render([%{"_type" => "mystery_meat", "foo" => "bar"}])
    assert is_binary(html)
    refute html =~ "mystery_meat"
  end
end
