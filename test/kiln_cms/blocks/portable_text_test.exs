defmodule KilnCMS.Blocks.PortableTextTest do
  @moduledoc "TipTap ↔ Portable Text ↔ HTML interchange (decision D12)."
  use ExUnit.Case, async: true

  alias KilnCMS.Blocks.PortableText

  defp tiptap(content), do: %{"type" => "doc", "content" => content}

  describe "from_tiptap/1 → to_html/1" do
    test "headings, paragraphs and inline marks" do
      doc =
        tiptap([
          %{
            "type" => "heading",
            "attrs" => %{"level" => 2},
            "content" => [%{"type" => "text", "text" => "Title"}]
          },
          %{
            "type" => "paragraph",
            "content" => [
              %{"type" => "text", "text" => "Hello "},
              %{"type" => "text", "text" => "world", "marks" => [%{"type" => "bold"}]}
            ]
          }
        ])

      html = doc |> PortableText.from_tiptap() |> PortableText.to_html()

      assert html =~ "<h2>Title</h2>"
      assert html =~ "<p>Hello <strong>world</strong></p>"
    end

    test "blockquote flattens its wrapped paragraph" do
      doc =
        tiptap([
          %{
            "type" => "blockquote",
            "content" => [
              %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "quoted"}]}
            ]
          }
        ])

      html = doc |> PortableText.from_tiptap() |> PortableText.to_html()
      assert html =~ "<blockquote>quoted</blockquote>"
    end

    test "link marks become markDefs and render as anchors" do
      doc =
        tiptap([
          %{
            "type" => "paragraph",
            "content" => [
              %{
                "type" => "text",
                "text" => "click",
                "marks" => [%{"type" => "link", "attrs" => %{"href" => "https://x.test"}}]
              }
            ]
          }
        ])

      pt = PortableText.from_tiptap(doc)
      assert [%{"markDefs" => [%{"_type" => "link", "href" => "https://x.test"}]}] = pt
      assert PortableText.to_html(pt) =~ ~s(<a href="https://x.test">click</a>)
    end

    test "text is HTML-escaped" do
      doc =
        tiptap([
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "a < b & c"}]}
        ])

      assert doc |> PortableText.from_tiptap() |> PortableText.to_html() =~ "a &lt; b &amp; c"
    end
  end

  describe "to_plain_text/1" do
    test "flattens prose for search/embeddings" do
      doc =
        tiptap([
          %{
            "type" => "heading",
            "attrs" => %{"level" => 1},
            "content" => [%{"type" => "text", "text" => "Title"}]
          },
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "Body text"}]}
        ])

      text = doc |> PortableText.from_tiptap() |> PortableText.to_plain_text()
      assert text =~ "Title"
      assert text =~ "Body text"
      refute text =~ "<"
    end
  end

  describe "edge cases" do
    test "from_tiptap is idempotent on PT input and tolerant of junk" do
      pt = [%{"_type" => "block", "style" => "normal", "children" => []}]
      assert PortableText.from_tiptap(pt) == pt
      assert PortableText.from_tiptap(nil) == []
      assert PortableText.to_html(nil) == ""
      assert PortableText.to_plain_text(nil) == ""
    end

    test "accepts a JSON string" do
      json =
        Jason.encode!(
          tiptap([%{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "hi"}]}])
        )

      assert json |> PortableText.from_tiptap() |> PortableText.to_html() == "<p>hi</p>"
    end
  end
end
