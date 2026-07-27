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

    test "stega-encodes plain-string custom fields, skipping parsed values" do
      json = %{
        "type" => "herb",
        "id" => "doc-4",
        "title" => "Ren Shen",
        "slug" => "ren-shen",
        "blocks" => [],
        "custom_fields" => %{
          "scientific_name" => "Panax ginseng",
          "dosages" => ~s([{"form":"decoction","amount":"3-9g"}]),
          "profile" => ~s({"taste":"sweet"}),
          "monograph_url" => "https://example.com/ren-shen.pdf",
          "empty" => "",
          "rating" => 5
        }
      }

      out = VisualEditing.annotate(json)
      cf = out["custom_fields"]

      # A plain string is encoded with the doc address + field name, no block —
      # the bridge deep-links these to the structured editor's ?focus= (#442).
      assert Stega.decode(cf["scientific_name"]) ==
               %{
                 "type" => "herb",
                 "id" => "doc-4",
                 "slug" => "ren-shen",
                 "field" => "scientific_name"
               }

      assert Stega.clean(cf["scientific_name"]) == "Panax ginseng"

      # Values consumers parse are untouched: JSON-encoded structures and URLs
      # (an invisible tail would corrupt JSON.parse or an src/href).
      assert cf["dosages"] == ~s([{"form":"decoction","amount":"3-9g"}])
      assert cf["profile"] == ~s({"taste":"sweet"})
      assert cf["monograph_url"] == "https://example.com/ren-shen.pdf"
      # Blank and non-string values pass through.
      assert cf["empty"] == ""
      assert cf["rating"] == 5
    end

    test "a document without custom_fields is unchanged by the custom-fields pass" do
      json = %{"type" => "post", "id" => "doc-5", "title" => "T", "blocks" => []}
      refute Map.has_key?(VisualEditing.annotate(json), "custom_fields")
    end
  end
end
