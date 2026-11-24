defmodule KilnCMSWeb.BlockViewTest do
  @moduledoc """
  `KilnCMSWeb.BlockComponents.view_blocks/1` — the render maps every block
  surface (delivery, the previews, the in-context editor) is built from, taken
  straight from the typed blocks now that the legacy bridge is deprecated
  (#1537) — and the deprecation markers themselves.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Blocks
  alias KilnCMSWeb.BlockComponents

  test "rich text renders through the block's own serializer, Portable Text first" do
    body = Blocks.PortableText.from_html("<p>Fresh <strong>prose</strong></p>")

    assert [%{type: "rich_text", content: html, id: "r1"}] =
             BlockComponents.view_blocks([
               %Blocks.RichText{id: "r1", body: body, legacy_html: "<p>stale copy</p>"}
             ])

    assert html == "<p>Fresh <strong>prose</strong></p>"
  end

  test "unconverted legacy_html still renders, sanitized" do
    assert [%{content: html}] =
             BlockComponents.view_blocks([
               %Blocks.RichText{
                 body: [],
                 legacy_html: ~s|<p onclick="x()">old</p><script>1</script>|
               }
             ])

    assert html =~ "<p>old</p>"
    refute html =~ "onclick"
    refute html =~ "<script"
  end

  test "stored maps of any shape are typed first — a legacy columns tree included" do
    stored = [
      %{
        "type" => "columns",
        "data" => %{
          "layout" => "1-1",
          "columns" => [
            %{"blocks" => [%{"type" => "heading", "content" => "Left"}]},
            %{"blocks" => [%{"_type" => "image", "url" => "https://x.test/a.png", "alt" => "A"}]}
          ]
        }
      }
    ]

    assert [%{type: "columns", columns: [left, right], style: style}] =
             BlockComponents.view_blocks(stored)

    assert [%{type: "heading", content: "Left"}] = left.blocks
    assert [%{type: "image", content: "https://x.test/a.png", alt: "A"}] = right.blocks
    assert style =~ "grid-template-columns"
  end

  # Every core block type has a view of its own (#2767): the `custom` fallback
  # is what left video, audio and file blocks as an empty `<p>` on the live
  # page while the fired artifact carried the player. A new core block without
  # a clause fails here, not on a reader's page.
  test "every core block type has a view of its own, never the empty custom fallback" do
    for module <- Blocks.core_modules() -- [Blocks.Custom] do
      assert [%{type: type}] = BlockComponents.view_blocks([struct(module)])
      assert type != "custom", "#{inspect(module)} falls through to the custom view"
    end
  end

  describe "video, audio and file blocks (#2767)" do
    setup do
      video = %Blocks.Video{
        id: "v1",
        media_id: "11111111-1111-1111-1111-111111111111",
        poster_media_id: "22222222-2222-2222-2222-222222222222",
        captions_media_id: "33333333-3333-3333-3333-333333333333",
        captions_label: "English",
        captions_lang: "en-GB",
        autoplay: true,
        loop: true,
        title: "Kiln tour",
        caption: "Ten minutes in the studio"
      }

      audio = %Blocks.Audio{
        id: "a1",
        media_id: "44444444-4444-4444-4444-444444444444",
        loop: true,
        title: "Episode 1"
      }

      file = %Blocks.File{
        id: "f1",
        media_id: "55555555-5555-5555-5555-555555555555",
        title: "Price list",
        filename: "prices.pdf",
        byte_size: 2_400_000,
        description: "Spring catalog"
      }

      %{blocks: [video, audio, file]}
    end

    test "render exactly the fired artifact's `:web` HTML", %{blocks: blocks} do
      views = BlockComponents.view_blocks(blocks)

      assert Enum.map(views, & &1.type) == ["video", "audio", "file"]

      for {block, view} <- Enum.zip(blocks, views) do
        html = render_view(view)
        assert html =~ IO.iodata_to_binary(Blocks.render(block, :web))
        assert html =~ ~s(data-block-id="#{block.id}")
        refute html =~ ~r/<p>\s*<\/p>/
      end
    end

    test "the player and the link point at the authorizing routes", %{blocks: blocks} do
      html = blocks |> BlockComponents.view_blocks() |> Enum.map_join(&render_view/1)

      assert html =~ ~s(src="/media/11111111-1111-1111-1111-111111111111/stream")
      assert html =~ ~s(poster="/media/22222222-2222-2222-2222-222222222222/stream")

      assert html =~
               ~s(<track kind="captions" src="/media/33333333-3333-3333-3333-333333333333/stream")

      assert html =~ ~s(<audio src="/media/44444444-4444-4444-4444-444444444444/stream")
      assert html =~ ~s(href="/media/55555555-5555-5555-5555-555555555555/download" download)
      assert html =~ "kiln-file-size"
    end

    test "a block with no source renders its own empty placeholder, not a paragraph" do
      for {block, class} <- [
            {%Blocks.Video{}, "kiln-video"},
            {%Blocks.Audio{}, "kiln-audio"},
            {%Blocks.File{}, "kiln-file"}
          ] do
        [view] = BlockComponents.view_blocks([block])
        html = render_view(view)

        assert html =~ ~s(<div class="#{class}"></div>)
        refute html =~ "<p>"
      end
    end

    test "text fields are escaped and a javascript: url never reaches an attribute" do
      pasted = %Blocks.Video{
        url: "https://cdn.test/v.mp4",
        poster_url: "javascript:alert(2)",
        caption: "<script>alert(3)</script>"
      }

      html = [pasted] |> BlockComponents.view_blocks() |> Enum.map_join(&render_view/1)
      assert html =~ ~s(src="https://cdn.test/v.mp4")
      refute html =~ "javascript:"
      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;alert(3)&lt;/script&gt;"

      # A `javascript:` source is no source: the placeholder, no player.
      html =
        [%Blocks.Video{url: "javascript:alert(1)"}]
        |> BlockComponents.view_blocks()
        |> Enum.map_join(&render_view/1)

      refute html =~ "javascript:"
      refute html =~ "<video"
    end
  end

  test "an unexpanded fragment renders nothing, not an empty paragraph" do
    assert [%{type: "fragment", content: nil} = view] =
             BlockComponents.view_blocks([%Blocks.Fragment{id: "fr1"}])

    html = render_view(view)
    refute html =~ "<p>"
    assert html =~ ~r/<div[^>]* data-block-id="fr1">\s*<\/div>/
  end

  describe "heading levels (#2769)" do
    test "levels 1 to 6 carry through and render at their own tag, as fired" do
      for level <- 1..6 do
        block = %Blocks.Heading{text: "Level #{level}", level: level}

        assert [%{type: "heading", level: ^level} = view] = BlockComponents.view_blocks([block])
        html = render_view(view)

        assert html =~ "<h#{level}>Level #{level}</h#{level}>"
        assert html =~ IO.iodata_to_binary(Blocks.render(block, :web))
      end
    end

    # The block's own clamp, not a second copy of it: anything outside 1..6
    # renders as an h2, as the fired artifact does, never the nearest bound.
    test "an out-of-range or malformed level renders as h2, as the artifact does" do
      for level <- [0, 7, -1, nil, 2.5, "3"] do
        block = %Blocks.Heading{text: "Odd", level: level}

        assert [%{level: 2} = view] = BlockComponents.view_blocks([block])
        assert render_view(view) =~ "<h2>Odd</h2>"
        assert IO.iodata_to_binary(Blocks.render(block, :web)) == "<h2>Odd</h2>"
      end
    end

    test "a hand-built heading map without a level renders as h2" do
      html = render_view(%{type: "heading", content: "Bare", anchor: "bare"})
      assert html =~ ~s(<h2 id="bare">Bare</h2>)
    end
  end

  describe "the legacy block bridge, at 1.0 (#1543)" do
    test "to_legacy/1, from_legacy/1 and KilnCMS.CMS.Block are gone" do
      exports = KilnCMS.CMS.TypedBlocks.__info__(:functions)

      refute {:to_legacy, 1} in exports
      refute {:from_legacy, 1} in exports
      refute Code.ensure_loaded?(Module.concat([KilnCMS, CMS, Block]))
    end

    test "legacy_html stays a deprecated fallback in the exported block schema" do
      schema = Kiln.Block.JsonSchema.for_module(Blocks.RichText)

      assert %{"deprecated" => true} = schema["properties"]["legacy_html"]
      refute Map.has_key?(schema["properties"]["body"], "deprecated")
    end
  end

  defp render_view(view), do: render_component(&BlockComponents.render_block/1, block: view)
end
