defmodule KilnCMS.SchemaExportTest do
  @moduledoc """
  The delivery schema export (#430).

  The half that cannot be a compile-time artifact: dynamic content types and
  custom fields are rows, per organization, so two sites on one deployment get
  two different documents. These tests are the reason the export takes an
  `org_id` at all.

  Not async: `ContentTypes.dynamic_all/1` reads across the table (its cache is
  off in tests for exactly this reason), so a shared sandbox is required.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.SchemaExport

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "sx-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp org(name) do
    Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
      name: name,
      slug: "#{name}-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  defp type_name, do: "widget#{System.unique_integer([:positive])}"

  setup do
    %{actor: admin(), org: org("sx")}
  end

  describe "document assembly" do
    test "the root is a oneOf over the content types, each addressable in $defs", %{org: org} do
      document = SchemaExport.json_schema(org_id: org.id)

      assert document["$schema"] == "https://json-schema.org/draft/2020-12/schema"

      refs = Enum.map(document["oneOf"], & &1["$ref"])
      assert "#/$defs/content_page" in refs
      assert "#/$defs/content_post" in refs

      for "#/$defs/" <> name <- refs, do: assert(Map.has_key?(document["$defs"], name))
    end

    test "a document schema mirrors the :json artifact's own keys", %{org: org} do
      page = SchemaExport.json_schema(org_id: org.id)["$defs"]["content_page"]

      # Exactly the keys `KilnCMS.Firing.Engine.compose/4` writes for `:json`.
      assert page["properties"] |> Map.keys() |> Enum.sort() ==
               ~w(blocks custom_fields id locale slug title type)

      assert page["properties"]["type"] == %{"const" => "page"}
      assert page["properties"]["blocks"]["items"] == %{"$ref" => "#/$defs/block"}
      assert page["additionalProperties"] == false
    end

    test "the block union comes along", %{org: org} do
      document = SchemaExport.json_schema(org_id: org.id)

      assert Map.has_key?(document["$defs"], "block")
      assert Map.has_key?(document["$defs"], "block_heading")
      assert "heading" in document["x-kiln"]["blocks"]
    end

    test "base_url becomes the document $id", %{org: org} do
      document = SchemaExport.json_schema(org_id: org.id, base_url: "https://example.com")
      assert document["$id"] == "https://example.com/api/schema"
    end

    test "without base_url there is no $id — a relative $ref still resolves", %{org: org} do
      refute Map.has_key?(SchemaExport.json_schema(org_id: org.id), "$id")
    end
  end

  describe "custom fields" do
    test "a definition becomes a typed property on its content type", %{actor: actor, org: org} do
      CMS.create_field_definition!(
        %{
          content_type: :page,
          name: "subtitle",
          label: "Subtitle",
          field_type: :string,
          help_text: "Shown under the title."
        },
        actor: actor,
        tenant: org
      )

      fields =
        SchemaExport.json_schema(org_id: org.id)["$defs"]["content_page"]["properties"][
          "custom_fields"
        ]

      assert fields["properties"]["subtitle"]["type"] == ["string", "null"]

      # `help_text` is admin-authored editor guidance behind an editor-gated read
      # policy, and it is rendered on no public surface. It is not schema, and it
      # does not go out on an anonymous endpoint.
      refute fields["properties"]["subtitle"]["description"]
      refute Jason.encode!(fields) =~ "Shown under the title."

      # Open: a point-in-time read serves the values stored at that instant,
      # which may include fields since removed from the registry.
      assert fields["additionalProperties"] == true
    end

    test "a select's options are neither published nor pinned as an enum",
         %{actor: actor, org: org} do
      CMS.create_field_definition!(
        %{
          content_type: :page,
          name: "tier",
          label: "Tier",
          field_type: :select,
          options: ["embargoed_q4", "zephyr_launch"]
        },
        actor: actor,
        tenant: org
      )

      fields = custom_fields(org, "content_page")

      # No `enum`, on two independent grounds. It would be wrong — firing never
      # re-coerces, so narrowing the option list leaves published documents
      # carrying a value outside it — and the vocabulary is editorial, not
      # structural, so an anonymous caller has no business reading it.
      refute fields["properties"]["tier"]["enum"]
      assert fields["properties"]["tier"]["type"] == ["string", "null"]
      refute Jason.encode!(fields) =~ "embargoed_q4"
    end

    test "a composite Kiln.FieldType declares its parts", %{actor: actor, org: org} do
      CMS.create_field_definition!(
        %{content_type: :page, name: "where", label: "Where", field_type: :geolocation},
        actor: actor,
        tenant: org
      )

      where = custom_fields(org, "content_page")["properties"]["where"]

      assert where["type"] == ["object", "null"]
      assert where["properties"]["lat"] == %{"type" => "number"}
      assert where["properties"]["lng"] == %{"type" => "number"}

      # No `required`: `input_part.required?` tracks the *definition's* required
      # flag, which is an editor concern — the same reason nothing else in
      # `custom_fields` is required either.
      refute where["required"]
    end

    test "a field type whose stored value diverges from its widget declares it",
         %{actor: actor, org: org} do
      CMS.create_field_definition!(
        %{content_type: :page, name: "cadence", label: "Cadence", field_type: :recurrence},
        actor: actor,
        tenant: org
      )

      cadence = custom_fields(org, "content_page")["properties"]["cadence"]

      # `exdates` renders as one comma-separated text input but `cast/2` stores
      # a list, so widget inference would have typed it `string`.
      assert cadence["properties"]["exdates"]["type"] == "array"
      assert cadence["properties"]["rrule"]["type"] == "string"
    end

    test "a computed field is unconstrained — its type follows the formula",
         %{actor: actor, org: org} do
      CMS.create_field_definition!(
        %{
          content_type: :page,
          name: "words",
          label: "Words",
          field_type: :computed,
          compute: "{{ word_count(body) }}"
        },
        actor: actor,
        tenant: org
      )

      words = custom_fields(org, "content_page")["properties"]["words"]

      # A single `{{ … }}` template delivers the native value, so this field
      # serves an integer while the widget is a text input.
      refute words["type"]
      assert words["description"] =~ "native value"
    end

    test "a plugin field type falls back to its declared input kind", %{actor: actor, org: org} do
      CMS.create_field_definition!(
        %{content_type: :page, name: "quality", label: "Quality", field_type: :rating},
        actor: actor,
        tenant: org
      )

      assert custom_fields(org, "content_page")["properties"]["quality"]["type"] ==
               ["number", "null"]
    end

    test "no field definition is required — firing does not invent a missing value",
         %{actor: actor, org: org} do
      CMS.create_field_definition!(
        %{
          content_type: :page,
          name: "mandatory",
          label: "Mandatory",
          field_type: :string,
          required: true
        },
        actor: actor,
        tenant: org
      )

      refute Map.has_key?(custom_fields(org, "content_page"), "required")
    end
  end

  describe "dynamic content types" do
    test "are exported with their own field definitions", %{actor: actor, org: org} do
      name = type_name()

      definition =
        CMS.create_type_definition!(%{name: name, label: "Widget"}, actor: actor, tenant: org)

      CMS.create_field_definition!(
        %{
          type_definition_id: definition.id,
          name: "torque",
          label: "Torque",
          field_type: :integer
        },
        actor: actor,
        tenant: org
      )

      schema =
        SchemaExport.json_schema(org_id: org.id)["$defs"][SchemaExport.content_def_name(name)]

      assert schema["x-kiln-content-type-source"] == "dynamic"
      assert schema["properties"]["type"] == %{"const" => name}

      assert schema["properties"]["custom_fields"]["properties"]["torque"]["type"] ==
               ["integer", "null"]
    end

    test "one site's types never appear in another's schema", %{actor: actor, org: org} do
      other = org("sx-other")
      name = type_name()

      CMS.create_type_definition!(%{name: name, label: "Widget"}, actor: actor, tenant: org)

      assert name in SchemaExport.json_schema(org_id: org.id)["x-kiln"]["content_types"]
      refute name in SchemaExport.json_schema(org_id: other.id)["x-kiln"]["content_types"]
    end
  end

  describe "filtering" do
    test "types restricts the export, in the order asked for", %{org: org} do
      document = SchemaExport.json_schema(org_id: org.id, types: ["post", "page"])

      assert document["x-kiln"]["content_types"] == ["post", "page"]

      assert Enum.map(document["oneOf"], & &1["$ref"]) ==
               ~w(#/$defs/content_post #/$defs/content_page)
    end

    test "a filtered-out type is absent from $defs entirely", %{org: org} do
      document = SchemaExport.json_schema(org_id: org.id, types: ["post"])

      assert Map.has_key?(document["$defs"], "content_post")
      refute Map.has_key?(document["$defs"], "content_page")
    end

    test "an unknown type name raises rather than silently exporting everything", %{org: org} do
      assert_raise ArgumentError, ~r/unknown content type\(s\): nope/, fn ->
        SchemaExport.json_schema(org_id: org.id, types: ["nope"])
      end
    end

    test "blocks_only drops the documents and the root oneOf", %{org: org} do
      document = SchemaExport.json_schema(org_id: org.id, blocks_only: true)

      assert document["x-kiln"]["content_types"] == []
      refute Map.has_key?(document, "oneOf")
      assert Map.has_key?(document["$defs"], "block")
      refute Enum.any?(Map.keys(document["$defs"]), &String.starts_with?(&1, "content_"))
    end
  end

  test "the whole document is JSON-encodable", %{org: org} do
    assert {:ok, _json} = Jason.encode(SchemaExport.json_schema(org_id: org.id))
  end

  defp custom_fields(org, def_name) do
    SchemaExport.json_schema(org_id: org.id)["$defs"][def_name]["properties"]["custom_fields"]
  end
end
