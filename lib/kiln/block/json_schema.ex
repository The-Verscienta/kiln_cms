defmodule Kiln.Block.JsonSchema do
  @moduledoc """
  JSON Schema (draft 2020-12) projection of the `Kiln.Block` registry (#430).

  One block definition already fans out into an embedded Ash resource, a
  storage-union member, and a set of serializers. This adds the missing one: a
  machine-readable description of the **`:json` delivery shape**, so a typed
  client generating against `/api/content/:type/:slug` has something to
  generate *from*.

  ## Which shape this describes

  The `:json` artifact, not the authoring/storage one. Those differ: an
  `image`'s stored `media_id` never reaches the `:json` render, and a `video`'s
  stored `media_id`/`url` pair is resolved into a single `src`. The write API's
  authoring shape is already described by the OpenAPI document at
  `/api/json/open_api`; this is the read side, which had nothing.

  Blocks are derived from their `field` declarations. A block whose `:json`
  render projects rather than mirrors patches the derived schema through
  `c:Kiln.Block.Renderer.json_schema/0`, which lives next to the render it
  describes — and `test/kiln/block/json_schema_test.exs` asserts the two agree
  for every registered block, so the pair cannot drift silently.

  ## Shape of the output

  `defs/1` returns a `$defs` map holding one object schema per block
  (`block_heading`, `block_image`, …), the discriminated union under `block`,
  and the shared `portable_text_block` a `:rich_text` field's items point at.
  Container blocks reference `#/$defs/block` recursively, which the Ash type
  system cannot express (a union member listing the union is a compile-time
  cycle — see `KilnCMS.Blocks.Columns`) but JSON Schema can.

  `KilnCMS.SchemaExport` assembles these into the full document served at
  `GET /api/schema` and written by `mix kiln.export.schema`.
  """

  alias Kiln.Block.Field
  alias Kiln.Block.Info

  @block_def "block"
  @portable_text_def "portable_text_block"

  # The patch directive, `x-`-prefixed like every other Kiln extension in this
  # file (`x-kiln-block`, `x-kiln-block-version`). `patch/2` merges unrecognized
  # keys through verbatim, so a bare `drop` would be indistinguishable from a
  # real keyword — both to a reader and to a future draft that defines one.
  @drop_key "x-kiln-drop"

  @doc "The key a `c:Kiln.Block.Renderer.json_schema/0` patch uses to remove a property."
  @spec drop_key() :: String.t()
  def drop_key, do: @drop_key

  @doc "The `$defs` key for one block's object schema (`:heading` → `block_heading`)."
  @spec def_name(atom() | String.t()) :: String.t()
  def def_name(name), do: "block_" <> to_string(name)

  @doc "A `$ref` pointing at the block union — what a container block's children are."
  @spec block_ref() :: map()
  def block_ref, do: %{"$ref" => "#/$defs/#{@block_def}"}

  @doc """
  The `_id` property every `:json`-rendered block carries.

  Injected by `KilnCMS.Blocks.render/2` rather than declared as a field: blocks
  are `_type`-tagged maps that would otherwise drop identity, and this is the
  anchor the visual-editing bridge maps a rendered value back to.
  """
  @spec id_property() :: map()
  def id_property do
    %{
      "type" => "string",
      "format" => "uuid",
      "description" =>
        "Stable block id, the addressing anchor for the visual-editing bridge. " <>
          "Absent on a block that has never been persisted."
    }
  end

  @doc """
  Every `$defs` entry for `modules`: one object schema per block, the `block`
  union over them, and the shared Portable Text definition.

  Modules that are not `Kiln.Block`s (no `block` declaration) are skipped
  rather than raising — the registry scan is duck-typed, and one stale beam
  should not take the whole export down.
  """
  @spec defs([module()]) :: %{String.t() => map()}
  def defs(modules) do
    blocks = block_modules(modules)

    blocks
    |> Map.new(&{def_name(Info.name(&1)), for_module(&1)})
    |> Map.put(@block_def, %{
      "title" => "Block",
      "description" => "Any block in a fired `:json` artifact, tagged by `_type`.",
      "oneOf" => refs(blocks),
      "discriminator" => %{"propertyName" => "_type"}
    })
    |> Map.put(@portable_text_def, portable_text_schema())
  end

  @doc """
  The `Kiln.Block` modules among `modules`, deduplicated by `_type` and sorted.

  Exported because every caller needs the *same* filtered list — the `$defs`
  keys, the union's `$ref`s and the document's `x-kiln.blocks` inventory would
  otherwise disagree, and the two that skipped the filter would raise on a
  module the third silently dropped.

  Deduplication is by `_type`, not by module: nothing enforces name uniqueness
  across plugins (`Kiln.Plugins.blocks/0` is a bare concat), and two modules
  claiming `:image` would otherwise put `#/$defs/block_image` into `oneOf`
  twice — making every image block match two branches of an exactly-one union.
  """
  @spec block_modules([module()]) :: [module()]
  def block_modules(modules) do
    modules
    |> Enum.filter(&block_module?/1)
    |> Enum.uniq_by(&Info.name/1)
    |> Enum.sort_by(&Info.name/1)
  end

  @doc """
  The discriminated union over `modules`.

  `discriminator` is an OpenAPI keyword rather than a JSON Schema one, so
  validators ignore it and code generators that understand it get a tagged
  union instead of an N-way `oneOf` probe. The `oneOf` alone is already
  unambiguous — every member pins `_type` to a distinct `const`.
  """
  @spec union([module()]) :: map()
  def union(modules), do: defs(modules)[@block_def]

  defp refs(blocks), do: Enum.map(blocks, &%{"$ref" => "#/$defs/#{def_name(Info.name(&1))}"})

  @doc """
  The object schema for one block module: derived from its `field` declarations,
  then patched by its `c:Kiln.Block.Renderer.json_schema/0` if it defines one.
  """
  @spec for_module(module()) :: map()
  def for_module(module) do
    derived = derived(module)

    # `Code.ensure_loaded?` first: this probe is the *only* dispatch for the
    # optional callback (`use Kiln.Block` declares no default to override), so
    # against a module the VM has not loaded yet — an interactive-mode `mix`
    # task is the normal way to get there — a bare `function_exported?` returns
    # false and the block silently exports its underived schema.
    if Code.ensure_loaded?(module) and function_exported?(module, :json_schema, 0) do
      patch(derived, module.json_schema())
    else
      derived
    end
  end

  @doc """
  JSON Schema for one Kiln field type.

  `nullable?` widens the type to admit `null`, which every non-required field
  needs: a `:json` render emits its declared keys whether or not they carry a
  value.
  """
  @spec type_schema(term(), boolean()) :: map()
  def type_schema(type, nullable? \\ true)

  def type_schema({:array, inner}, nullable?),
    do: nullable(%{"type" => "array", "items" => type_schema(inner, false)}, nullable?)

  def type_schema(:rich_text, nullable?) do
    nullable(
      %{
        "type" => "array",
        "items" => %{"$ref" => "#/$defs/#{@portable_text_def}"},
        "description" => "Portable Text — the canonical rich-text representation (D12)."
      },
      nullable?
    )
  end

  def type_schema(:integer, nullable?), do: nullable(%{"type" => "integer"}, nullable?)
  def type_schema(:float, nullable?), do: nullable(%{"type" => "number"}, nullable?)
  def type_schema(:boolean, nullable?), do: nullable(%{"type" => "boolean"}, nullable?)

  def type_schema(:date, nullable?),
    do: nullable(%{"type" => "string", "format" => "date"}, nullable?)

  def type_schema(:datetime, nullable?),
    do: nullable(%{"type" => "string", "format" => "date-time"}, nullable?)

  def type_schema(:url, nullable?),
    do: nullable(%{"type" => "string", "format" => "uri"}, nullable?)

  def type_schema(:email, nullable?),
    do: nullable(%{"type" => "string", "format" => "email"}, nullable?)

  def type_schema(:image, nullable?),
    do: nullable(%{"type" => "string", "format" => "uri-reference"}, nullable?)

  def type_schema(:color, nullable?),
    do: nullable(%{"type" => "string", "description" => "CSS color."}, nullable?)

  def type_schema(:slug, nullable?), do: nullable(%{"type" => "string"}, nullable?)
  def type_schema(:string, nullable?), do: nullable(%{"type" => "string"}, nullable?)

  def type_schema(type, nullable?) when type in [:map, :object, :reference],
    do: nullable(%{"type" => "object"}, nullable?)

  # An unrecognized field type is an honest "anything": the DSL takes `:any`, so
  # a plugin may declare a type this table has never heard of. Refusing to export
  # the whole block over one field would be the worse answer.
  def type_schema(_other, _nullable?), do: %{}

  @doc """
  An array of closed objects whose every key is a present, non-null string.

  The shape four container blocks (`faq`, `how_to`, `accordion`, `gallery`)
  arrive at by normalizing their `{:array, :map}` field — each back-fills every
  key to a trimmed string and `List.wrap`s the array, so neither the array nor
  any value is ever null. Derivation cannot see that; a `{:array, :map}` field
  only derives to "array of object".
  """
  @spec object_array([String.t()]) :: map()
  def object_array(keys) do
    %{
      "type" => "array",
      "items" => %{
        "type" => "object",
        "properties" => Map.new(keys, &{&1, %{"type" => "string"}}),
        "required" => Enum.sort(keys),
        "additionalProperties" => false
      }
    }
  end

  @doc """
  The resolved playable source `video` and `audio` both project.

  Their stored `media_id`/`url` pair is two authoring routes to one href; the
  `:json` render collapses them into `src` and drops the raw `url`.
  """
  @spec resolved_src() :: map()
  def resolved_src do
    %{
      "type" => "string",
      "format" => "uri-reference",
      "description" => "Playable source, resolved from `media_id` or the authored url."
    }
  end

  @doc """
  `PascalCase` for a snake- or kebab-cased name (`:rich_text` → `"RichText"`).

  One spelling shared by the JSON Schema `title`s and the `.d.ts` type names —
  they addressed the same name two different ways before, so a hyphenated
  dynamic type came out differently in each.
  """
  @spec pascal(atom() | String.t()) :: String.t()
  def pascal(name) do
    name
    |> to_string()
    |> String.split(~r/[_\-]/, trim: true)
    |> Enum.map_join("", &String.capitalize/1)
  end

  @doc """
  Widen a schema to admit `null`.

  Only `type`-carrying schemas can be widened this way; a `$ref` or an empty
  schema is returned untouched (a `$ref` sibling `type` is ignored under
  2020-12, so writing one would be a lie).
  """
  @spec nullable(map(), boolean()) :: map()
  def nullable(schema, false), do: schema

  def nullable(%{"type" => type} = schema, true) when is_binary(type),
    do: %{schema | "type" => [type, "null"]}

  def nullable(schema, true), do: schema

  # ── derivation ──────────────────────────────────────────────────────────────

  defp derived(module) do
    name = Info.name(module)
    fields = Info.fields(module)

    properties =
      fields
      |> Map.new(&{to_string(&1.name), field_schema(&1)})
      |> Map.put("_type", %{"const" => to_string(name)})
      |> Map.put("_id", id_property())

    required =
      ["_type" | for(f <- fields, f.required, do: to_string(f.name))]
      |> Enum.sort()

    %{
      "type" => "object",
      "title" => title(name),
      "x-kiln-block" => to_string(name),
      "x-kiln-block-version" => Info.version(module),
      "properties" => properties,
      "required" => required,
      # Closed on purpose: the point of the export is that a consumer can tell
      # a typo from a field. `_version` is deliberately absent — it is a storage
      # concern the `:json` render does not project.
      "additionalProperties" => false
    }
  end

  # A `required: true` field is non-nullable; anything else stays nullable — a
  # `:json` render emits its declared keys whether or not they carry a value.
  #
  # `required: true` becomes `allow_nil?: false` on the embedded attribute, so a
  # top-level block cannot carry a nil there. Until #935, a block nested inside
  # a container *could*: `KilnCMS.CMS.TypedBlocks.struct_from_typed_map/1`
  # rebuilt children with a bare `struct/2`, which never ran the Ash cast, so a
  # stored `%{"_type" => "heading"}` inside a `columns` fired `"text" => nil`.
  # Both shapes came back through the same `#/$defs/block_heading`, so the
  # schema had to admit their union or a legitimately published document
  # matched zero `oneOf` branches.
  #
  # `TypedBlocks.sanitize_children/2` now runs every nested child through the
  # same Ash cast a top-level block gets (`KilnCMS.CMS.BlockUnion`'s cast entry
  # points), refusing the whole write if a required nested field is missing —
  # so a nested block is exactly as valid as a top-level one, and this can go
  # back to reflecting that.
  #
  # `required` still earns its place independent of nullability: it says the
  # **key is present**, which is what `additionalProperties: false` and the
  # `.d.ts` optionality read.
  defp field_schema(%Field{} = field) do
    field.type
    |> type_schema(!field.required)
    |> put_unless_nil("description", field.description)
    |> put_default(field.default)
  end

  defp put_unless_nil(schema, _key, nil), do: schema
  defp put_unless_nil(schema, key, value), do: Map.put(schema, key, value)

  # A `default` only reaches the document when it is JSON-native. The DSL takes
  # `:any`, so a block may default a field to a struct or a function capture —
  # `Jason` would raise on those at encode time, which is a strange way for a
  # schema export to fail.
  defp put_default(schema, nil), do: schema

  defp put_default(schema, default) do
    if json_native?(default), do: Map.put(schema, "default", default), else: schema
  end

  defp json_native?(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: true

  defp json_native?(value) when is_list(value), do: Enum.all?(value, &json_native?/1)
  defp json_native?(%_struct{}), do: false

  defp json_native?(value) when is_map(value),
    do: Enum.all?(value, fn {k, v} -> (is_binary(k) or is_atom(k)) and json_native?(v) end)

  defp json_native?(_), do: false

  # ── patching ────────────────────────────────────────────────────────────────

  defp patch(derived, override) when is_map(override) do
    {dropped, override} = Map.pop(override, @drop_key, [])
    {props, override} = Map.pop(override, "properties", %{})

    dropped = Enum.map(dropped, &to_string/1)

    properties =
      derived
      |> Map.fetch!("properties")
      |> Map.drop(dropped)
      |> Map.merge(props)

    derived
    |> Map.merge(override)
    |> Map.put("properties", properties)
    # A dropped key must leave `required` too. `additionalProperties: false`
    # forbids what `properties` omits, so dropping a `required: true` field and
    # leaving it listed yields a schema demanding a key it also bans — one no
    # instance can satisfy, and nothing downstream would say so.
    |> Map.update("required", [], &(&1 -- dropped))
  end

  # ── shared definitions ──────────────────────────────────────────────────────

  defp portable_text_schema do
    %{
      "type" => "object",
      "title" => "PortableTextBlock",
      "description" =>
        "One Portable Text node (D12). Open by design: Portable Text is an " <>
          "extensible convention rather than a fixed schema, and a consumer that " <>
          "does not recognize a node's `_type` is expected to skip it.",
      "properties" => %{
        "_type" => %{"type" => "string"},
        "_key" => %{"type" => "string"}
      },
      # Not `required`, though every well-formed node has one: nothing on the
      # write path enforces it. `TypedBlocks.normalize_body/1` passes any list
      # through untouched and `PortableText.sanitize_block/1`'s catch-all only
      # scrubs `markDefs`, so a headless write of `body: [%{"text" => "hi"}]` is
      # stored and fired verbatim. The schema describes what is served.
      "additionalProperties" => true
    }
  end

  defp block_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :spark_dsl_config, 0) and
      not is_nil(Info.name(module))
  rescue
    # A module that is not a Spark DSL at all raises rather than returning nil.
    _ -> false
  end

  defp title(name), do: pascal(name) <> "Block"
end
