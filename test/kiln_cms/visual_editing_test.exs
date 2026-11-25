defmodule KilnCMS.VisualEditingTest do
  @moduledoc """
  The visual-editing bridge server side (#355): stega encode/decode, and the
  `annotate/1` pass over a fired `:json` artifact map.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.VisualEditing
  alias KilnCMS.VisualEditing.Stega

  describe "Stega" do
    test "encodes an invisible payload that decodes back, leaving the visible text intact" do
      payload = %{"type" => "post", "id" => "abc-123", "field" => "title"}
      encoded = Stega.encode("Hello world", payload)

      # The visible text is unchanged once the invisible tag is stripped.
      assert Stega.clean(encoded) == "Hello world"
      # …and the tail actually carries hidden characters.
      assert String.length(encoded) > String.length("Hello world")
      # …which round-trip back to the payload.
      assert Stega.decode(encoded) == payload
    end

    test "decode returns nil for un-encoded text" do
      assert Stega.decode("just some text") == nil
      assert Stega.decode("") == nil
    end

    test "encode is a no-op on empty/blank strings" do
      assert Stega.encode("", %{"x" => 1}) == ""
    end

    test "clean removes tag characters even without sentinels" do
      # A lone tag character (no START/STOP) is still stripped by clean/1.
      stray = "abc" <> List.to_string([0xE0041]) <> "def"
      assert Stega.clean(stray) == "abcdef"
    end

    test "handles unicode / multibyte visible text" do
      payload = %{"field" => "title"}
      encoded = Stega.encode("café — 日本語", payload)
      assert Stega.clean(encoded) == "café — 日本語"
      assert Stega.decode(encoded) == payload
    end
  end

  describe "annotate/1" do
    test "stega-encodes the document title and block string fields, keying blocks by _id" do
      json = %{
        "type" => "post",
        "id" => "doc-1",
        "title" => "My title",
        "slug" => "my-title",
        "blocks" => [
          %{"_type" => "heading", "_id" => "b1", "text" => "A heading", "level" => 2},
          %{"_type" => "image", "_id" => "b2", "url" => "https://x/y.png", "alt" => "Alt text"}
        ]
      }

      out = VisualEditing.annotate(json)

      # Title carries the document address (no block — it's a document scalar).
      assert Stega.decode(out["title"]) ==
               %{"type" => "post", "id" => "doc-1", "slug" => "my-title", "field" => "title"}

      assert Stega.clean(out["title"]) == "My title"

      [heading, image] = out["blocks"]
      # Heading text carries the doc address + the block id to focus.
      assert Stega.decode(heading["text"]) ==
               %{
                 "type" => "post",
                 "id" => "doc-1",
                 "slug" => "my-title",
                 "field" => "text",
                 "block" => "b1"
               }

      # Image alt is encoded…
      assert Stega.decode(image["alt"]) ==
               %{
                 "type" => "post",
                 "id" => "doc-1",
                 "slug" => "my-title",
                 "field" => "alt",
                 "block" => "b2"
               }

      # …but identifiers/URLs/slug are left byte-for-byte (encoding would corrupt them).
      assert image["url"] == "https://x/y.png"
      assert out["slug"] == "my-title"
      assert heading["level"] == 2
    end

    test "carries locale in the stega address when the artifact has one (#1104)" do
      json = %{
        "type" => "page",
        "id" => "doc-fr",
        "slug" => "about",
        "locale" => "fr",
        "title" => "À propos",
        "blocks" => [%{"_type" => "heading", "_id" => "b1", "text" => "Titre", "level" => 2}]
      }

      out = VisualEditing.annotate(json)

      assert Stega.decode(out["title"]) ==
               %{
                 "type" => "page",
                 "id" => "doc-fr",
                 "slug" => "about",
                 "locale" => "fr",
                 "field" => "title"
               }

      assert Stega.decode(hd(out["blocks"])["text"])["locale"] == "fr"
    end

    test "recurses into nested container (columns) children" do
      json = %{
        "type" => "page",
        "id" => "doc-2",
        "title" => "T",
        "blocks" => [
          %{
            "_type" => "columns",
            "_id" => "c1",
            "layout" => "2",
            "columns" => [
              %{"blocks" => [%{"_type" => "heading", "_id" => "nested1", "text" => "Nested"}]}
            ]
          }
        ]
      }

      out = VisualEditing.annotate(json)
      [%{"columns" => [%{"blocks" => [nested]}]}] = out["blocks"]

      assert Stega.decode(nested["text"]) ==
               %{
                 "type" => "page",
                 "id" => "doc-2",
                 "slug" => nil,
                 "field" => "text",
                 "block" => "nested1"
               }

      assert Stega.clean(nested["text"]) == "Nested"
    end

    test "is a no-op when the map lacks a document address" do
      json = %{"title" => "no id here", "blocks" => []}
      assert VisualEditing.annotate(json) == json
    end

    test "stega-encodes each span of a rich-text Portable Text body" do
      json = %{
        "type" => "post",
        "id" => "doc-3",
        "slug" => "rt",
        "title" => "T",
        "blocks" => [
          %{
            "_type" => "rich_text",
            "_id" => "r1",
            "body" => [
              %{
                "_type" => "block",
                "_key" => "b0",
                "children" => [
                  %{"_type" => "span", "text" => "Hello ", "marks" => []},
                  %{"_type" => "span", "text" => "world", "marks" => ["strong"]}
                ]
              }
            ]
          }
        ]
      }

      out = VisualEditing.annotate(json)
      [%{"body" => [%{"children" => [s1, s2]}]}] = out["blocks"]

      # Every span carries the rich-text block address; a click anywhere resolves
      # to block "r1".
      assert Stega.decode(s1["text"]) ==
               %{
                 "type" => "post",
                 "id" => "doc-3",
                 "slug" => "rt",
                 "field" => "body",
                 "block" => "r1"
               }

      assert Stega.clean(s1["text"]) == "Hello "
      assert Stega.decode(s2["text"])["block"] == "r1"
      assert Stega.clean(s2["text"]) == "world"
    end

    test "stega-encodes table cell spans and leaves code blocks clean" do
      json = %{
        "type" => "post",
        "id" => "doc-4",
        "slug" => "tc",
        "title" => "T",
        "blocks" => [
          %{
            "_type" => "rich_text",
            "_id" => "r2",
            "body" => [
              %{
                "_type" => "table",
                "_key" => "b0",
                "rows" => [
                  %{
                    "cells" => [
                      %{
                        "header" => true,
                        "children" => [%{"_type" => "span", "text" => "Name", "marks" => []}],
                        "markDefs" => []
                      }
                    ]
                  }
                ]
              },
              %{
                "_type" => "block",
                "_key" => "b1",
                "style" => "code",
                "language" => "elixir",
                "children" => [%{"_type" => "span", "text" => "IO.puts(1)", "marks" => []}],
                "markDefs" => []
              }
            ]
          }
        ]
      }

      out = VisualEditing.annotate(json)
      [%{"body" => [table, code]}] = out["blocks"]

      # Table text is clickable: the cell span carries the block address.
      [%{"cells" => [%{"children" => [cell_span]}]}] = table["rows"]
      assert Stega.decode(cell_span["text"])["block"] == "r2"
      assert Stega.clean(cell_span["text"]) == "Name"

      # Code stays byte-identical — invisible tag characters inside code would
      # corrupt client-side highlighting and copy-paste.
      assert [%{"text" => "IO.puts(1)"}] = code["children"]
    end

    test "stega-encodes plain-string custom fields, skipping parsed values" do
      json = %{
        "type" => "recipe",
        "id" => "doc-4",
        "title" => "Banana Bread",
        "slug" => "banana-bread",
        "blocks" => [],
        "custom_fields" => %{
          "subtitle" => "A quick loaf",
          "servings" => ~s([{"form":"loaf","amount":"8-10"}]),
          "profile" => ~s({"taste":"sweet"}),
          "recipe_card_url" => "https://example.com/banana-bread.pdf",
          "empty" => "",
          "rating" => 5
        }
      }

      out = VisualEditing.annotate(json)
      cf = out["custom_fields"]

      # A plain string is encoded with the doc address + field name, no block —
      # the bridge deep-links these to the structured editor's ?focus= (#442).
      assert Stega.decode(cf["subtitle"]) ==
               %{
                 "type" => "recipe",
                 "id" => "doc-4",
                 "slug" => "banana-bread",
                 "field" => "subtitle"
               }

      assert Stega.clean(cf["subtitle"]) == "A quick loaf"

      # Values consumers parse are untouched: JSON-encoded structures and URLs
      # (an invisible tail would corrupt JSON.parse or an src/href).
      assert cf["servings"] == ~s([{"form":"loaf","amount":"8-10"}])
      assert cf["profile"] == ~s({"taste":"sweet"})
      assert cf["recipe_card_url"] == "https://example.com/banana-bread.pdf"
      # Blank and non-string values pass through.
      assert cf["empty"] == ""
      assert cf["rating"] == 5
    end

    test "a document without custom_fields is unchanged by the custom-fields pass" do
      json = %{"type" => "post", "id" => "doc-5", "title" => "T", "blocks" => []}
      refute Map.has_key?(VisualEditing.annotate(json), "custom_fields")
    end
  end

  # #2770: only prose is encoded. URLs and identifiers on a block are what a
  # front end requests or looks up, so an invisible tail would 404 or miss.
  describe "annotate/1 leaves URLs and identifiers alone (#2770)" do
    @media_id "0b0e8c1e-3f4a-4c2b-9d8e-5a6b7c8d9e0f"

    # One realistic `:json` render per block type that carries URL or id
    # strings: `{block, keys that must come out byte-for-byte, prose keys}`.
    @fixtures [
      {%{
         "_type" => "video",
         "src" => "/media/#{@media_id}/stream",
         "media_id" => @media_id,
         "title" => "Launch day",
         "caption" => "Filmed on site",
         "poster" => "/media/#{@media_id}/poster.jpg",
         "captions_url" => "/media/#{@media_id}/captions.vtt",
         "captions_label" => "English captions",
         "captions_lang" => "en"
       }, ~w(src media_id poster captions_url captions_lang), ~w(title caption captions_label)},
      {%{
         "_type" => "audio",
         "src" => "https://cdn.example.com/a/episode.mp3",
         "media_id" => @media_id,
         "title" => "Episode one"
       }, ~w(src media_id), ~w(title)},
      {%{
         "_type" => "file",
         "media_id" => @media_id,
         "download_url" => "/media/#{@media_id}/download",
         "filename" => "annual-report.pdf",
         "content_type" => "application/pdf",
         "title" => "Annual report",
         "description" => "The full year in numbers"
       }, ~w(media_id download_url filename content_type), ~w(title description)},
      {%{
         "_type" => "embed",
         "url" => "https://www.youtube.com/watch?v=abc",
         "resolved_url" => "https://www.youtube.com/embed/abc",
         "thumbnail_url" => "https://i.ytimg.com/vi/abc/hq.jpg",
         "title" => "A cached provider title"
       }, ~w(url resolved_url thumbnail_url title), []},
      {%{
         "_type" => "image",
         "url" => "https://x.example/y.png",
         "media_id" => @media_id,
         "alt" => "A kiln at dusk"
       }, ~w(url media_id), ~w(alt)},
      {%{
         "_type" => "claim",
         "text" => "Kilns reach 1300 degrees",
         "source_title" => "Ceramics handbook",
         "source_url" => "https://example.org/handbook"
       }, ~w(source_url), ~w(text source_title)},
      {%{"_type" => "form", "form_slug" => "contact"}, ~w(form_slug), []},
      {%{
         "_type" => "newsletter_signup",
         "heading" => "Stay in touch",
         "action" => "/newsletter/subscribe",
         "honeypot_field" => "website"
       }, ~w(action honeypot_field), ~w(heading)},
      {%{"_type" => "gallery", "title" => "Site photos", "layout" => "grid"}, ~w(layout),
       ~w(title)},
      {%{"_type" => "columns", "layout" => "2", "gap" => "md", "columns" => []}, ~w(layout gap),
       []},
      {%{"_type" => "custom", "legacy_type" => "hero", "content" => "<div>Hi</div>"},
       ~w(legacy_type content), []}
    ]

    defp annotate_one(block) do
      json = %{
        "type" => "page",
        "id" => "doc-2770",
        "slug" => "s",
        "title" => "T",
        "blocks" => [Map.put(block, "_id", "blk")]
      }

      [out] = VisualEditing.annotate(json)["blocks"]
      out
    end

    for {block, untouched, prose} <- @fixtures do
      @block block
      @untouched untouched
      @prose prose

      test "#{block["_type"]}: #{Enum.join(untouched, ", ")} come out unencoded" do
        out = annotate_one(@block)

        for key <- @untouched do
          assert out[key] == @block[key], "#{key} was encoded: #{inspect(out[key])}"
        end

        for key <- @prose do
          assert Stega.clean(out[key]) == @block[key]
          assert Stega.decode(out[key])["field"] == key, "#{key} was not encoded"
        end
      end
    end

    test "a heading's and a paragraph's text are still encoded" do
      heading = annotate_one(%{"_type" => "heading", "text" => "Getting started", "level" => 2})

      quote =
        annotate_one(%{"_type" => "quote", "text" => "Fire is patient.", "citation" => "Ana"})

      assert Stega.decode(heading["text"])["block"] == "blk"
      assert Stega.clean(heading["text"]) == "Getting started"
      assert Stega.decode(quote["text"])["field"] == "text"
      assert Stega.decode(quote["citation"])["field"] == "citation"
    end

    # Table-driven over every registered block type: a string under a key the
    # block doesn't declare as plain-text prose stays as it is, even when it
    # reads as prose, and a declared prose key is encoded.
    test "every registered block encodes exactly its declared prose fields" do
      for {type, module} <- KilnCMS.Blocks.registry() do
        prose =
          for {name, :text} <- Kiln.Block.Info.translatable(module), do: Atom.to_string(name)

        others =
          for %{name: name} <- Kiln.Block.Info.fields(module),
              key = Atom.to_string(name),
              key not in prose,
              do: key

        block =
          Map.new(prose ++ others ++ ~w(src poster download_url), &{&1, "Plain words here"})
          |> Map.put("_type", Atom.to_string(type))

        out = annotate_one(block)

        for key <- others ++ ~w(src poster download_url) do
          assert out[key] == "Plain words here", "#{type}.#{key} was encoded"
        end

        for key <- prose do
          assert Stega.decode(out[key])["field"] == key, "#{type}.#{key} was not encoded"
        end
      end
    end

    test "a block whose type isn't registered is left as is" do
      block = %{"_type" => "no_such_block", "text" => "Some words"}
      assert annotate_one(block)["text"] == "Some words"
    end

    test "a prose field holding a URL, path, UUID or token is left as is" do
      for value <- [
            "https://example.com/a",
            "mailto:hi@example.com",
            "/media/x/stream",
            "../up.png",
            @media_id,
            "video/mp4",
            "report.pdf",
            "contact_form"
          ] do
        out = annotate_one(%{"_type" => "heading", "text" => value})
        assert out["text"] == value, "#{value} was encoded"
      end
    end

    test "custom fields skip paths, UUIDs and identifier-like tokens" do
      json = %{
        "type" => "recipe",
        "id" => "doc-cf",
        "title" => "T",
        "blocks" => [],
        "custom_fields" => %{
          "subtitle" => "A quick loaf",
          "hero" => "/media/#{@media_id}/original",
          "asset" => @media_id,
          "sku" => "loaf_large",
          "mime" => "image/webp"
        }
      }

      cf = VisualEditing.annotate(json)["custom_fields"]

      assert Stega.decode(cf["subtitle"])["field"] == "subtitle"
      assert cf["hero"] == "/media/#{@media_id}/original"
      assert cf["asset"] == @media_id
      assert cf["sku"] == "loaf_large"
      assert cf["mime"] == "image/webp"
    end
  end
end
