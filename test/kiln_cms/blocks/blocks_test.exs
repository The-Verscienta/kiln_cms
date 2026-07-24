defmodule KilnCMS.BlocksTest do
  @moduledoc "Registry + serializer dispatch over typed blocks (D10/D11)."
  use ExUnit.Case, async: true

  alias KilnCMS.Blocks

  describe "registry" do
    test "discovers block modules keyed by their _type discriminator" do
      registry = Blocks.registry()

      assert registry[:heading] == KilnCMS.Blocks.Heading
      assert registry[:image] == KilnCMS.Blocks.Image
      assert registry[:rich_text] == KilnCMS.Blocks.RichText
    end

    test "fetch/1 resolves a module by type" do
      assert {:ok, KilnCMS.Blocks.Image} = Blocks.fetch(:image)
      assert :error = Blocks.fetch(:nonexistent)
    end
  end

  describe "rich_text :json surface" do
    test "canonical Portable Text body passes through" do
      block = %KilnCMS.Blocks.RichText{
        body: [%{"_type" => "block", "children" => [%{"_type" => "span", "text" => "hi"}]}]
      }

      assert %{"_type" => "rich_text", "body" => [%{"_type" => "block"} = _]} =
               KilnCMS.Blocks.render(block, :json)
    end

    test "TipTap-authored legacy_html survives when body is empty" do
      block = %KilnCMS.Blocks.RichText{
        body: [],
        legacy_html: ~s|<p>prose lives here</p><script>alert(1)</script>|
      }

      assert %{"_type" => "rich_text", "body" => [], "legacy_html" => html} =
               KilnCMS.Blocks.render(block, :json)

      # The prose ships; the sanitizer strips what the allowlist forbids.
      assert html =~ "prose lives here"
      refute html =~ "<script"
    end
  end

  describe "dispatch" do
    test "render/2 routes to the block's module" do
      image = %KilnCMS.Blocks.Image{url: "/x.png", alt: "an x", caption: "cap"}

      html = image |> Blocks.render(:web) |> IO.iodata_to_binary()
      assert html =~ ~s(<img src="/x.png" alt="an x"/>)
      assert html =~ "<figcaption>cap</figcaption>"

      assert %{"@type" => "ImageObject", "url" => "/x.png"} = Blocks.render(image, :json_ld)
    end

    test "render/2 over a rich text block renders Portable Text" do
      pt = [
        %{
          "_type" => "block",
          "style" => "normal",
          "children" => [%{"_type" => "span", "text" => "hi", "marks" => []}]
        }
      ]

      block = %KilnCMS.Blocks.RichText{body: pt}

      assert Blocks.render(block, :web) == "<p>hi</p>"
      assert Blocks.search_text(block) == "hi"
    end

    test "rich text falls back to legacy_html when body is empty" do
      block = %KilnCMS.Blocks.RichText{body: [], legacy_html: "<p>old</p>"}
      assert Blocks.render(block, :web) == "<p>old</p>"
      assert Blocks.search_text(block) == "old"
    end
  end
end
