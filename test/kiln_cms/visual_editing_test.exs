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
  end
end
