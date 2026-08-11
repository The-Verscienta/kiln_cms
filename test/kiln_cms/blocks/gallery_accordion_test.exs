defmodule KilnCMS.Blocks.GalleryAccordionTest do
  @moduledoc """
  The two block types added by #482: an image collection that fires
  `ImageGallery`, and a collapsible container that fires **nothing**.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Blocks
  alias KilnCMS.Blocks.Accordion
  alias KilnCMS.Blocks.Gallery
  alias KilnCMS.CMS.TypedBlocks

  defp gallery(images, attrs \\ %{}) do
    struct(%Gallery{_type: "gallery", images: images}, attrs)
  end

  defp accordion(panels, attrs \\ %{}) do
    struct(%Accordion{_type: "accordion", panels: panels}, attrs)
  end

  describe "gallery" do
    test ":web renders one figure per image, with alt and caption" do
      block =
        gallery([
          %{"url" => "/uploads/a.jpg", "alt" => "A cat", "caption" => "Tabby"},
          %{"url" => "/uploads/b.jpg", "alt" => "A dog", "caption" => ""}
        ])

      html = block |> Blocks.render(:web) |> IO.iodata_to_binary()

      assert html =~ ~s(<img src="/uploads/a.jpg" alt="A cat")
      assert html =~ "<figcaption>Tabby</figcaption>"
      assert html =~ ~s(alt="A dog")
      # The second image has no caption, so it gets no figcaption element at all
      # rather than an empty one.
      assert html |> String.split("figcaption") |> length() == 3
    end

    test ":web escapes alt and caption" do
      block = gallery([%{"url" => "/a.jpg", "alt" => ~s(" onerror="x), "caption" => "<b>hi</b>"}])

      html = block |> Blocks.render(:web) |> IO.iodata_to_binary()

      refute html =~ ~s(onerror="x")
      refute html =~ "<b>hi</b>"
      assert html =~ "&lt;b&gt;hi&lt;/b&gt;"
    end

    test ":web rejects a javascript: src" do
      block = gallery([%{"url" => "javascript:alert(1)", "alt" => "x"}])

      html = block |> Blocks.render(:web) |> IO.iodata_to_binary()

      refute html =~ "javascript:"
      assert html =~ ~s(src="")
    end

    test ":json_ld is one ImageGallery node holding every image" do
      block =
        gallery(
          [
            %{"url" => "/a.jpg", "alt" => "A", "caption" => "Cap"},
            %{"url" => "/b.jpg", "alt" => "B"}
          ],
          %{title: "Site photographs"}
        )

      assert %{"@type" => "ImageGallery", "name" => "Site photographs", "image" => images} =
               Blocks.render(block, :json_ld)

      assert [
               %{"@type" => "ImageObject", "url" => "/a.jpg", "name" => "A", "caption" => "Cap"},
               %{"@type" => "ImageObject", "url" => "/b.jpg", "name" => "B"}
             ] = images
    end

    test ":json_ld is nil when there is nothing to describe" do
      assert Blocks.render(gallery([]), :json_ld) == nil
      # An item with no url is not an image, whatever else it carries.
      assert Blocks.render(gallery([%{"alt" => "orphan"}]), :json_ld) == nil
    end

    test "layout_style/1 resolves through an allowlist, never the raw value" do
      assert Gallery.layout_style("masonry") =~ "column-count"

      injected = Gallery.layout_style("grid\";background:url(evil)")
      refute injected =~ "evil"
      # An unknown layout falls back to the default rather than to no style.
      assert injected == Gallery.layout_style("grid")
      assert Gallery.layout_style(nil) == Gallery.layout_style("grid")
    end

    test "media_ids/1 lists the referenced ids in order, skipping blanks" do
      block =
        gallery([
          %{"media_id" => "id-1", "url" => "/a.jpg"},
          %{"url" => "/pasted.jpg"},
          %{"media_id" => "id-2", "url" => "/b.jpg"}
        ])

      assert Gallery.media_ids(block) == ["id-1", "id-2"]
    end

    test "search_text/1 projects the title, alts and captions" do
      block =
        gallery([%{"url" => "/a.jpg", "alt" => "Kiln", "caption" => "at work"}], %{title: "Shots"})

      assert Blocks.search_text(block) == "Shots Kiln at work"
    end

    test "images/1 normalizes atom keys, missing keys and junk entries" do
      block = %Gallery{_type: "gallery", images: [%{url: "/a.jpg", alt: " padded "}, "junk", %{}]}

      assert [first, second] = Gallery.images(block)
      assert first == %{"media_id" => "", "url" => "/a.jpg", "alt" => "padded", "caption" => ""}
      assert second == %{"media_id" => "", "url" => "", "alt" => "", "caption" => ""}
    end
  end

  describe "accordion" do
    test ":json_ld is nil — the entire reason this block exists beside faq" do
      block = accordion([%{"title" => "Dimensions", "content" => "80cm"}])

      # An accordion looks exactly like an FAQ and means something else. Firing
      # FAQPage from it tells answer engines the page is a list of questions and
      # answers, which they act on. If this assertion ever goes green against a
      # node, the block has become a duplicate of `faq` with a different name.
      assert Blocks.render(block, :json_ld) == nil
      assert Blocks.render(accordion([]), :json_ld) == nil
    end

    test "faq still fires FAQPage, so the difference is real and not a regression" do
      faq = %KilnCMS.Blocks.Faq{
        _type: "faq",
        items: [%{"question" => "Why?", "answer" => "Because."}]
      }

      assert %{"@type" => "FAQPage"} = Blocks.render(faq, :json_ld)
    end

    test ":web renders details/summary per panel and escapes both fields" do
      block = accordion([%{"title" => "<b>T</b>", "content" => "Body"}])

      html = block |> Blocks.render(:web) |> IO.iodata_to_binary()

      assert html =~ "<details class=\"kiln-accordion-item\""
      assert html =~ "<summary>&lt;b&gt;T&lt;/b&gt;</summary>"
      assert html =~ "Body"
    end

    test "first_open opens only the first panel" do
      panels = [%{"title" => "One", "content" => "a"}, %{"title" => "Two", "content" => "b"}]

      opened =
        accordion(panels, %{first_open: true}) |> Blocks.render(:web) |> IO.iodata_to_binary()

      closed = accordion(panels) |> Blocks.render(:web) |> IO.iodata_to_binary()

      assert opened |> String.split(" open>") |> length() == 2
      refute closed =~ " open>"
    end

    test "a panel with no title is dropped — it would render an unopenable box" do
      block = accordion([%{"title" => "", "content" => "orphaned"}])

      html = block |> Blocks.render(:web) |> IO.iodata_to_binary()

      refute html =~ "orphaned"
      refute html =~ "<details"
    end

    test "search_text/1 and to_markdown/1 project every panel" do
      block = accordion([%{"title" => "Size", "content" => "Large"}], %{title: "Specs"})

      assert Blocks.search_text(block) == "Specs Size Large"
      assert Accordion.to_markdown(block) == "## Specs\n\n### Size\n\nLarge"
    end
  end

  describe "typed → legacy → typed round trip" do
    test "a gallery keeps its images, layout and title" do
      block =
        gallery(
          [%{"media_id" => "m1", "url" => "/a.jpg", "alt" => "A", "caption" => "C"}],
          %{title: "Shots", layout: "masonry"}
        )

      assert [%Gallery{} = back] =
               block |> List.wrap() |> TypedBlocks.to_legacy() |> TypedBlocks.to_typed()

      assert back.title == "Shots"
      assert back.layout == "masonry"

      assert Gallery.images(back) == [
               %{"media_id" => "m1", "url" => "/a.jpg", "alt" => "A", "caption" => "C"}
             ]
    end

    test "an accordion keeps its panels and first_open" do
      block =
        accordion([%{"title" => "T", "content" => "C"}], %{title: "Specs", first_open: true})

      assert [%Accordion{} = back] =
               block |> List.wrap() |> TypedBlocks.to_legacy() |> TypedBlocks.to_typed()

      assert back.title == "Specs"
      # A boolean has to survive the trip in both directions — it is written as a
      # real boolean and read back from jsonb, and form params make it a string.
      assert back.first_open == true
      assert Accordion.panels(back) == [%{"title" => "T", "content" => "C"}]
    end
  end

  describe "storage union" do
    test "a gallery casts, keeping its images as raw maps" do
      input = %{
        "_type" => "gallery",
        "layout" => "grid",
        "images" => [%{"url" => "/a.jpg", "alt" => "A", "caption" => "C"}]
      }

      assert {:ok, %Ash.Union{type: :gallery, value: %Gallery{} = block}} =
               Ash.Type.cast_input(KilnCMS.CMS.BlockUnion, input)

      assert block.layout == "grid"
      assert [%{"url" => "/a.jpg", "alt" => "A"}] = block.images
    end

    test "an accordion casts, keeping its panels as raw maps" do
      input = %{
        "_type" => "accordion",
        "first_open" => true,
        "panels" => [%{"title" => "T", "content" => "C"}]
      }

      assert {:ok, %Ash.Union{type: :accordion, value: %Accordion{} = block}} =
               Ash.Type.cast_input(KilnCMS.CMS.BlockUnion, input)

      assert block.first_open == true
      assert [%{"title" => "T", "content" => "C"}] = block.panels
    end

    test "an atom-keyed image url is sanitized too, not left beside a nil string key" do
      # Seeds, in-Elixir importers and plugins all produce atom-keyed maps, and
      # `Gallery.images/1` deliberately reads either. Updating only the "url"
      # string key would insert `"url" => nil` and leave `:url` untouched — and
      # `field_str/3`'s `Map.get(m, "url") || Map.get(m, :url)` then picks the
      # UNFILTERED one, straight into the fired JSON artifact.
      input = %{"_type" => "gallery", "images" => [%{url: "javascript:alert(1)", alt: "x"}]}

      assert {:ok, %Ash.Union{value: %Gallery{} = block}} =
               Ash.Type.cast_input(KilnCMS.CMS.BlockUnion, input)

      assert [%{"url" => "", "alt" => "x"}] = Gallery.images(block)
    end

    test "a non-binary image url is blanked rather than crashing the write" do
      # `HTMLSanitizer.safe_image_src/1` has no clause for a number, and the
      # inner values of an `{:array, :map}` are never type-cast — so an API or
      # import write of `{"url": 123}` would raise out of cast as a 500.
      input = %{"_type" => "gallery", "images" => [%{"url" => 123}, %{"url" => %{}}]}

      assert {:ok, %Ash.Union{value: %Gallery{} = block}} =
               Ash.Type.cast_input(KilnCMS.CMS.BlockUnion, input)

      assert Enum.map(Gallery.images(block), & &1["url"]) == ["", ""]
    end

    test "a gallery's item urls are sanitized on cast" do
      # The `image` block's url is cleaned by its own clause; a gallery's urls
      # live a level down inside an `{:array, :map}` field, so without a
      # dedicated clause they would be the one image src reaching storage
      # unfiltered — a `javascript:` href straight through to delivery.
      input = %{
        "_type" => "gallery",
        "images" => [
          %{"url" => "javascript:alert(1)", "alt" => "x"},
          %{"url" => "/fine.jpg", "alt" => "y"}
        ]
      }

      assert {:ok, %Ash.Union{value: %Gallery{images: images}}} =
               Ash.Type.cast_input(KilnCMS.CMS.BlockUnion, input)

      assert [%{"url" => ""}, %{"url" => "/fine.jpg"}] = images
    end
  end
end
