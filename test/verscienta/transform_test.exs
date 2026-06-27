defmodule Verscienta.TransformTest do
  @moduledoc "Pure transform rules — no DB or network."
  use ExUnit.Case, async: true

  alias Verscienta.{Mapping, Transform}

  defp herbs, do: Mapping.config_for("herbs")
  defp formulas, do: Mapping.config_for("formulas")

  describe "field_definitions/2" do
    test "infers a consistent type per field across rows and excludes structural fields" do
      items = [
        %{
          "id" => 1,
          "title" => "A",
          "slug" => "a",
          "status" => "published",
          "review_count" => 2,
          "molecular_weight" => 1.5,
          "sourcing_organic" => true,
          "synonyms" => ["x"]
        },
        %{
          "id" => 2,
          "title" => "B",
          "slug" => "b",
          "review_count" => 7,
          "molecular_weight" => 3,
          "sourcing_organic" => false,
          "synonyms" => ["y", "z"]
        }
      ]

      defs = Map.new(Transform.field_definitions(herbs(), items), &{&1.name, &1.field_type})

      # structural fields never become custom fields
      refute Map.has_key?(defs, "title")
      refute Map.has_key?(defs, "slug")
      refute Map.has_key?(defs, "status")
      refute Map.has_key?(defs, "id")

      assert defs["review_count"] == :integer
      assert defs["molecular_weight"] == :float
      assert defs["sourcing_organic"] == :boolean
      # a JSON array is not scalar -> stored as text
      assert defs["synonyms"] == :text
    end
  end

  describe "plan/2" do
    test "maps core attrs, rich-text sections to blocks, and JSON to encoded custom fields" do
      item = %{
        "id" => 1,
        "status" => "published",
        "title" => "Ginseng",
        "slug" => "ginseng",
        "synonyms" => ["Asian ginseng"],
        "sourcing_organic" => true,
        "botanical_description" => "<p>A perennial.</p>",
        "therapeutic_uses" => "<p>Tonifies qi.</p>",
        "contraindications" => "   ",
        "tags" => [%{"id" => 1, "slug" => "adaptogen"}]
      }

      plan = Transform.plan(herbs(), item)

      assert plan.title == "Ginseng"
      assert plan.slug == "ginseng"
      assert plan.state_action == :publish

      # two non-empty sections -> heading + rich_text each; the blank one is skipped
      assert Enum.map(plan.text_blocks, & &1.type) == [:heading, :rich_text, :heading, :rich_text]
      assert Enum.at(plan.text_blocks, 0).content == "Botanical Description"

      # scalar preserved; list JSON-encoded losslessly
      assert plan.custom_fields["sourcing_organic"] == true
      assert plan.custom_fields["synonyms"] == ~s(["Asian ginseng"])

      assert plan.tag_refs == [{"herb-tag", "herb-tag-adaptogen"}]
    end

    test "status drives the publish/archive/draft action" do
      base = %{"id" => 1, "title" => "X", "slug" => "x"}

      assert Transform.plan(herbs(), Map.put(base, "status", "published")).state_action ==
               :publish

      assert Transform.plan(herbs(), Map.put(base, "status", "archived")).state_action == :archive
      assert Transform.plan(herbs(), Map.put(base, "status", "draft")).state_action == :draft
      # collections without a status field publish by default
      assert Transform.plan(formulas(), base).state_action == :publish
    end
  end

  describe "link_specs/2" do
    test "expands M2M relations and O2M children with metadata on the link" do
      item = %{
        "id" => 1,
        "title" => "Formula",
        "slug" => "f",
        "conditions" => [%{"id" => 5, "slug" => "fatigue"}],
        "ingredients" => [
          %{
            "id" => 9,
            "herb_id" => %{"id" => 2, "slug" => "ginseng"},
            "quantity" => 9,
            "unit" => "g",
            "role" => "Chief"
          }
        ]
      }

      specs = Transform.link_specs(formulas(), item)

      treats = Enum.find(specs, &(&1.kind == :treats))
      assert treats.target_collection == "conditions"
      assert treats.target_directus_id == 5
      assert treats.metadata == %{}

      ingredient = Enum.find(specs, &(&1.kind == :ingredient))
      assert ingredient.target_collection == "herbs"
      assert ingredient.target_directus_id == 2
      assert ingredient.metadata == %{"quantity" => 9, "unit" => "g", "role" => "Chief"}
    end
  end

  describe "media_spec/1" do
    test "prefers the Cloudflare URL the offload extension stores" do
      spec =
        Transform.media_spec(%{
          "id" => "f1",
          "filename_download" => "g.jpg",
          "type" => "image/jpeg",
          "cloudflare_url" => "https://cdn/g",
          "url" => "https://local/g",
          "width" => 100
        })

      assert spec.url == "https://cdn/g"
      assert spec.filename == "g.jpg"
      assert spec.width == 100
    end
  end
end
