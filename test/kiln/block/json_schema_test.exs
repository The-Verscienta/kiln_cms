defmodule Kiln.Block.JsonSchemaTest do
  @moduledoc """
  The exported block schema and the `:json` render must describe the same thing
  (#430).

  A schema derived from the DSL is a claim about code that lives somewhere
  else: `render/2`'s `:json` clause is hand-written, so an `image` that stops
  projecting `media_id` or a `video` that starts projecting a new key would
  silently make the published schema wrong. `describe "conformance"` closes
  that by rendering every registered block and comparing the result against its
  own exported schema — including plugin blocks, which the fixture plugin
  contributes here.
  """
  use ExUnit.Case, async: true

  alias Kiln.Block.Info
  alias Kiln.Block.JsonSchema
  alias KilnCMS.Blocks

  describe "derivation" do
    test "a block's fields become properties, tagged by a const _type" do
      schema = JsonSchema.for_module(KilnCMS.Blocks.Heading)

      assert schema["type"] == "object"
      assert schema["properties"]["_type"] == %{"const" => "heading"}
      # Non-nullable: `text` is `required: true`, and #935 made a nested child
      # exactly as valid as a top-level one, so the schema no longer has to
      # admit the union of "present" and "missing" for this field.
      assert schema["properties"]["text"] == %{"type" => "string"}
      assert schema["x-kiln-block-version"] == 2
    end

    test "a required field is listed as required — and is no longer nullable" do
      schema = JsonSchema.for_module(KilnCMS.Blocks.Claim)

      assert schema["required"] == ["_type", "text"]
      # `TypedBlocks.sanitize_children/2` now casts a nested child through the
      # same Ash `allow_nil?: false` a top-level block already enforced (#935),
      # so both shapes share this one definition without either being a lie.
      assert schema["properties"]["text"] == %{"type" => "string"}
      # An optional field stays nullable — a `:json` render always emits its
      # declared keys, whether or not they carry a value.
      assert schema["properties"]["source_title"]["type"] == ["string", "null"]
    end

    test "every block carries the _id delivery injects, and is closed" do
      schema = JsonSchema.for_module(KilnCMS.Blocks.Divider)

      assert schema["properties"]["_id"]["format"] == "uuid"
      assert schema["additionalProperties"] == false
    end

    test "_version is not exported — it is storage, not delivery" do
      schema = JsonSchema.for_module(KilnCMS.Blocks.Heading)
      refute Map.has_key?(schema["properties"], "_version")
    end

    test "a rich_text field points at the shared Portable Text definition" do
      schema = JsonSchema.for_module(KilnCMS.Blocks.RichText)

      assert schema["properties"]["body"]["items"] == %{"$ref" => "#/$defs/portable_text_block"}
      # Both render branches emit an array, so it is required and never null.
      assert "body" in schema["required"]
      assert schema["properties"]["body"]["type"] == "array"
    end

    test "declared defaults reach the schema" do
      schema = JsonSchema.for_module(KilnCMS.Blocks.Accordion)
      assert schema["properties"]["first_open"]["default"] == false
    end
  end

  describe "json_schema/0 patches" do
    test "x-kiln-drop removes a field the :json render does not project" do
      schema = JsonSchema.for_module(KilnCMS.Blocks.Image)

      refute Map.has_key?(schema["properties"], "media_id")
      assert Map.has_key?(schema["properties"], "url")
    end

    test "properties adds a computed key the DSL has no field for" do
      schema = JsonSchema.for_module(KilnCMS.Blocks.Video)

      assert schema["properties"]["src"]["type"] == "string"
      refute Map.has_key?(schema["properties"], "poster_media_id")
    end

    test "required is replaced wholesale" do
      assert JsonSchema.for_module(KilnCMS.Blocks.RichText)["required"] == ["_type", "body"]
    end

    # The trap the directive would otherwise set: `additionalProperties: false`
    # forbids what `properties` omits, so a dropped key left in `required` is
    # mandatory and banned at once — a schema nothing can satisfy.
    test "x-kiln-drop also removes the field from required" do
      defmodule DroppedRequired do
        use Kiln.Block

        block :dropped_required do
          field :gone, :string, required: true
          field :kept, :string
        end

        @impl Kiln.Block.Renderer
        def json_schema, do: %{"x-kiln-drop" => ["gone"]}
      end

      schema = JsonSchema.for_module(DroppedRequired)

      refute Map.has_key?(schema["properties"], "gone")
      refute "gone" in schema["required"]
      assert schema["required"] == ["_type"]
    end
  end

  describe "the union" do
    test "is a oneOf over every registered block, discriminated by _type" do
      defs = JsonSchema.defs(Blocks.modules())
      union = defs["block"]

      assert union["discriminator"] == %{"propertyName" => "_type"}

      refs = Enum.map(union["oneOf"], & &1["$ref"])
      assert "#/$defs/block_heading" in refs
      assert length(refs) == length(Blocks.modules())
      # A repeat would make every block of that type match two branches of an
      # exactly-one union; nothing enforces `_type` uniqueness across plugins.
      assert refs == Enum.uniq(refs)

      # Every ref resolves.
      for %{"$ref" => "#/$defs/" <> name} <- union["oneOf"], do: assert(Map.has_key?(defs, name))
    end

    test "container children recurse back into the union" do
      columns = JsonSchema.defs(Blocks.modules())["block_columns"]

      assert columns["properties"]["columns"]["items"]["properties"]["blocks"]["items"] ==
               %{"$ref" => "#/$defs/block"}
    end

    test "non-block modules are skipped rather than raising" do
      defs = JsonSchema.defs([KilnCMS.Blocks.Heading, Enum, __MODULE__])
      assert Map.has_key?(defs, "block_heading")
      assert length(defs["block"]["oneOf"]) == 1
    end
  end

  describe "conformance: the schema describes what render/2 emits" do
    setup do
      %{defs: JsonSchema.defs(Blocks.modules())}
    end

    # Validated with the real validator against the real `$defs`, so the item
    # shapes the patches declare (`gallery.images`, `accordion.panels`,
    # `columns.columns`) are checked to their leaves — a shallow key-set
    # comparison passed happily while `images` was missing a key.
    test "a populated block validates against its own exported schema", %{defs: defs} do
      for module <- Blocks.modules() do
        assert_valid(module |> populated() |> Blocks.render(:json), module, defs)
      end
    end

    test "the emptiest a block can legitimately be still validates", %{defs: defs} do
      # The other half of the branch coverage: `video`/`file`/`audio` take a
      # different `:json` path with no source, and `rich_text` takes its
      # legacy-HTML fallback. Required fields are filled (a bare `struct/2`
      # cannot come from a real write post-#935 — every `required: true` field
      # is `allow_nil?: false`, top-level and nested alike), everything else is
      # left nil/default.
      for module <- Blocks.modules() do
        assert_valid(module |> required_only() |> Blocks.render(:json), module, defs)
      end
    end

    # #935: a nested child is now cast through the same Ash `allow_nil?: false`
    # a top-level block always was (`TypedBlocks.sanitize_children/2`), so a
    # validly-authored one renders required fields exactly as non-null as its
    # top-level twin — through the very `$defs` entry both shapes share. The
    # write-time refusal of an *invalid* nested child (the other half of #935)
    # is covered at the write-action level in
    # `KilnCMS.CMS.NestedBlockValidationTest`, not here — this module only
    # asserts what a schema says about a rendered value, not what storage
    # accepts.
    test "a validly-cast nested child renders required fields non-null, like its top-level twin",
         %{defs: defs} do
      for module <- Blocks.modules() do
        type = to_string(Info.name(module))
        child_attrs = module |> required_only_attrs() |> Map.put("_type", type)

        nested =
          %{"_type" => "columns", "columns" => [%{"blocks" => [child_attrs]}]}
          |> KilnCMS.CMS.TypedBlocks.to_union_input()

        [child] =
          [nested]
          |> KilnCMS.CMS.TypedBlocks.to_typed()
          |> hd()
          |> Blocks.render(:json)
          |> Map.fetch!("columns")
          |> hd()
          |> Map.fetch!("blocks")

        assert_valid(child, module, defs)
      end
    end

    test "every block's required keys really are emitted", %{defs: defs} do
      for module <- Blocks.modules() do
        schema = defs[JsonSchema.def_name(Info.name(module))]
        rendered = module |> populated() |> Blocks.render(:json)
        missing = Enum.reject(schema["required"], &Map.has_key?(rendered, &1))

        assert missing == [],
               "#{inspect(module)}'s schema requires #{inspect(missing)}, " <>
                 "but a fully-populated block does not render them."
      end
    end
  end

  defp assert_valid(rendered, module, defs) do
    schema = defs[JsonSchema.def_name(Info.name(module))]
    document = %{"$defs" => defs}

    case KilnCMS.JsonSchemaValidator.validate(rendered, schema, document) do
      :ok ->
        :ok

      {:error, errors} ->
        flunk("""
        #{inspect(module)} renders :json output its own exported schema rejects.

        Rendered: #{inspect(rendered, pretty: true)}

        #{Enum.join(errors, "\n")}

        Reconcile them via `json_schema/0` (see Kiln.Block.Renderer).
        """)
    end
  end

  # A block with every declared field carrying a value of its declared type, so
  # the render takes its populated branch.
  defp populated(module) do
    module
    |> Info.fields()
    |> Enum.reduce(struct(module, id: Ecto.UUID.generate()), fn field, block ->
      Map.put(block, field.name, sample(field.type))
    end)
  end

  # A block with only its `required: true` fields filled — the emptiest a
  # block can legitimately be post-#935, since the write path can no longer
  # store one with a required field omitted (top-level or nested).
  defp required_only(module) do
    module
    |> Info.fields()
    |> Enum.filter(& &1.required)
    |> Enum.reduce(struct(module, id: Ecto.UUID.generate()), fn field, block ->
      Map.put(block, field.name, sample(field.type))
    end)
  end

  # Same, but as the string-keyed attrs map `BlockUnion`'s cast accepts (no
  # `_type`/`id` — the caller adds those).
  defp required_only_attrs(module) do
    module
    |> Info.fields()
    |> Enum.filter(& &1.required)
    |> Map.new(&{to_string(&1.name), sample(&1.type)})
  end

  defp sample(:integer), do: 3
  defp sample(:float), do: 1.5
  defp sample(:boolean), do: true
  defp sample(:date), do: ~D[2026-08-07]
  defp sample(:datetime), do: ~U[2026-08-07 00:00:00Z]
  defp sample(:url), do: "https://example.com/a"
  defp sample(:email), do: "editor@example.com"
  defp sample(:color), do: "#112233"
  defp sample(:rich_text), do: [%{"_type" => "block", "children" => []}]
  defp sample({:array, :map}), do: [%{}]
  defp sample({:array, inner}), do: [sample(inner)]
  defp sample(type) when type in [:map, :object, :reference], do: %{}
  defp sample(_scalar), do: "sample"
end
