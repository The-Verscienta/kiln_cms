defmodule KilnCMS.SchemaExport.Walk do
  @moduledoc """
  The JSON-Schema walk every type emitter shares.

  `KilnCMS.SchemaExport.TypeScript`, `KilnCMS.SchemaExport.Swift` and
  `KilnCMS.SchemaExport.Kotlin` read the exported **document**, never the
  block registry — so they cannot disagree with the JSON Schema about what a
  field is. This module is the one reading of that document: it resolves
  `$ref`/`$defs`, splits nullability out of a `["T", "null"]` type list,
  recognises `const`/`enum`, the `oneOf` block union, a nullable `$ref`
  (`anyOf: [$ref, null]`), closed versus open objects and arrays, and hands
  each emitter the same small, language-neutral model. An emitter only
  decides how to *spell*
  it, which is why a new target language is a formatting module and not a
  second schema reader that might read `nullable` differently.

  ## The model

  `model/2` returns:

    * `:format_version` — `x-kiln.artifact_format_version`, or `nil`.
    * `:shared`, `:blocks`, `:documents` — `t:decl/0`s, sorted by `$defs`
      name. A `$defs` entry that is itself a `oneOf` union is not a
      declaration; the block union is described by `:block_union` instead, and
      any other union is dropped (a `$ref` to one reads as `t:type/0`
      `{:ref, name}` with nothing behind it — emitters fall back to their
      "any JSON" type).
    * `:block_union` — `%{name: "block", tag: "_type", members: [...]}` in
      `oneOf` order, each member `%{def: "block_x", tag: "x" | nil}` (the
      member's `const` discriminator value), or `nil` without one.
    * `:document_union` — `%{tag: "type", members: [...]}` over the content
      definitions, sorted, shaped like the block union.
    * `:defs` — every `$defs` name mapped to `:object`, `:opaque` or `:union`,
      so an emitter can tell what a `{:ref, name}` lands on.

  A `t:type/0` is one of the tuples below. Anything not listed (`format`,
  `minimum`, `default`, `contentMediaType`, …) is dropped here, once, for
  every emitter: a generated type that lies about a constraint is worse than
  one that is merely loose about it.

  ## Closed variants

  A schema can narrow its own shape with a sibling `anyOf` of closed inline
  objects, optionally plus `{"type": "null"}` — `KilnCMS.CMS.FieldTypes.Range`
  says "two numbers or two dates" that way, beside a looser merged object
  (#2548). With `variants: true` (`KilnCMS.SchemaExport.TypeScript`) such a
  schema walks as `{:union, objects}`, nullable when the `anyOf` has a null
  member. Without it, the default for Swift and Kotlin, the `anyOf` is ignored
  and the merged object is what they declare: a union of inline structs would
  be their "any JSON" type, which is looser than the merged one.
  """

  @typedoc "A property of an object: its JSON key, whether it must be present, and its type."
  @type field :: %{
          key: String.t(),
          required?: boolean(),
          description: String.t() | nil,
          target_types: [String.t()],
          graphql_kind: String.t() | nil,
          type: type()
        }

  @typedoc "One walked schema."
  @type type ::
          {:ref, String.t()}
          | {:union, [type()]}
          | {:nullable, type()}
          | {:const, term()}
          | {:enum, [term()]}
          | {:array, type()}
          | {:object, [field()], open? :: boolean()}
          | :map
          | :integer
          | :number
          | :boolean
          | :string
          | :null
          | :unknown

  @typedoc """
  A top-level `$defs` entry. `{:object, fields, open?}` for a schema with
  `properties`; `:opaque` for one without (a lone `const`, an open object),
  which has nothing to declare.
  """
  @type decl :: %{
          name: String.t(),
          description: String.t() | nil,
          graphql: %{String.t() => String.t()} | nil,
          shape: {:object, [field()], boolean()} | :opaque
        }

  @type union :: %{
          name: String.t(),
          tag: String.t(),
          members: [%{def: String.t(), tag: term()}]
        }

  @type model :: %{
          format_version: term(),
          shared: [decl()],
          blocks: [decl()],
          documents: [decl()],
          block_union: union() | nil,
          document_union: union(),
          defs: %{String.t() => :object | :opaque | :union}
        }

  @block_union "block"

  @doc """
  Walk a schema document from `KilnCMS.SchemaExport.json_schema/1`.

  `variants: true` reads a closed-object `anyOf` as a union (see "Closed
  variants" above); the default ignores it.
  """
  @spec model(map(), keyword()) :: model()
  def model(document, opts \\ []) do
    defs = Map.get(document, "$defs", %{})

    {block_defs, rest} = Enum.split_with(defs, fn {name, _} -> block_def?(name) end)
    {content_defs, shared_defs} = Enum.split_with(rest, fn {name, _} -> content_def?(name) end)

    documents = declarations(content_defs, opts)

    %{
      format_version: document |> Map.get("x-kiln", %{}) |> Map.get("artifact_format_version"),
      shared: shared_defs |> Enum.reject(&union?/1) |> declarations(opts),
      blocks: block_defs |> Enum.reject(&union?/1) |> declarations(opts),
      documents: documents,
      block_union: block_union(defs),
      document_union: %{
        name: "document",
        tag: "type",
        members: Enum.map(documents, &%{def: &1.name, tag: tag_value(defs, &1.name, "type")})
      },
      defs: Map.new(defs, fn {name, schema} -> {name, def_kind(schema)} end)
    }
  end

  @doc "The `$defs` name a `$ref` points at (`#/$defs/block` → `block`)."
  @spec ref_target(String.t()) :: String.t()
  def ref_target(ref), do: ref |> String.split("/") |> List.last()

  @doc """
  Walk one schema into a `t:type/0`.

  The clause order is load-bearing. A `$ref` wins outright (2020-12 ignores
  nothing beside it, but every emitter reads it as the target). A type list
  is read **ahead of** `const`/`enum`: a nullable enum carries both keywords,
  and matching the value clause first would drop the `null` a delivery really
  does send.

  `opts` as for `model/2`.
  """
  @spec type(map(), keyword()) :: type()
  def type(schema, opts \\ [])

  def type(%{"$ref" => ref}, _opts), do: {:ref, ref_target(ref)}

  def type(%{"oneOf" => members}, opts), do: {:union, Enum.map(members, &type(&1, opts))}

  # A nullable `$ref` — 2020-12 has no other way to say it. The sibling `type`
  # list is there for generators that don't read `anyOf`; the pair is what
  # names the target.
  def type(%{"anyOf" => [%{"$ref" => _} = ref, %{"type" => "null"}]}, opts),
    do: {:nullable, type(ref, opts)}

  # Ahead of the type list: the `anyOf` narrows the merged shape beside it, and
  # a value must satisfy both, so the narrower one is the honest type.
  def type(%{"anyOf" => members} = schema, opts) do
    case opts[:variants] && closed_variants(members) do
      {objects, nullable?} ->
        union = {:union, Enum.map(objects, &type(&1, opts))}
        if nullable?, do: {:nullable, union}, else: union

      _ ->
        schema |> Map.delete("anyOf") |> type(opts)
    end
  end

  def type(%{"type" => types} = schema, opts) when is_list(types) do
    {nulls, rest} = Enum.split_with(types, &(&1 == "null"))

    inner =
      case Enum.map(rest, &type(Map.put(schema, "type", &1), opts)) do
        [] -> :null
        [one] -> one
        many -> {:union, many}
      end

    if nulls != [] and inner != :null, do: {:nullable, inner}, else: inner
  end

  def type(%{"const" => value}, _opts), do: {:const, value}
  def type(%{"enum" => values}, _opts), do: {:enum, values}

  def type(%{"type" => "array"} = schema, opts),
    do: {:array, type(Map.get(schema, "items", %{}), opts)}

  def type(%{"type" => "object"} = schema, opts) do
    case Map.get(schema, "properties") do
      nil -> :map
      properties -> {:object, fields(properties, schema, opts), open?(schema)}
    end
  end

  def type(%{"type" => "integer"}, _opts), do: :integer
  def type(%{"type" => "number"}, _opts), do: :number
  def type(%{"type" => "boolean"}, _opts), do: :boolean
  def type(%{"type" => "string"}, _opts), do: :string
  def type(%{"type" => "null"}, _opts), do: :null
  def type(_schema, _opts), do: :unknown

  # `{objects, nullable?}` when every member is a closed inline object or
  # `{"type": "null"}` and at least one is an object; `nil` for any other
  # `anyOf`, which is left to the clauses below it.
  defp closed_variants(members) when is_list(members) do
    {nulls, objects} = Enum.split_with(members, &(&1 == %{"type" => "null"}))

    if objects != [] and Enum.all?(objects, &closed_object?/1),
      do: {objects, nulls != []},
      else: nil
  end

  defp closed_variants(_members), do: nil

  defp closed_object?(%{
         "type" => "object",
         "properties" => %{},
         "additionalProperties" => false
       }),
       do: true

  defp closed_object?(_schema), do: false

  # ── declarations ────────────────────────────────────────────────────────────

  defp declarations(defs, opts) do
    defs
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.map(fn {name, schema} -> declaration(name, schema, opts) end)
  end

  defp declaration(name, %{"properties" => properties} = schema, opts),
    do: %{
      name: name,
      description: Map.get(schema, "description"),
      graphql: Map.get(schema, "x-kiln-graphql"),
      shape: {:object, fields(properties, schema, opts), open?(schema)}
    }

  defp declaration(name, schema, _opts),
    do: %{
      name: name,
      description: Map.get(schema, "description"),
      graphql: Map.get(schema, "x-kiln-graphql"),
      shape: :opaque
    }

  # Sorted by key: a schema written to disk is diffed, and map order past 32
  # keys is a hash order.
  defp fields(properties, schema, opts) do
    required = MapSet.new(Map.get(schema, "required", []))

    properties
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.map(fn {key, value} ->
      %{
        key: key,
        required?: MapSet.member?(required, key),
        description: Map.get(value, "description"),
        target_types: target_types(value),
        graphql_kind: Map.get(value, "x-kiln-graphql-kind"),
        type: type(value, opts)
      }
    end)
  end

  # A `:reference` custom field's allowed target types (R2) — an annotation,
  # not an `enum` on the snapshot's `type`, since a stored value may name a
  # type the field has since stopped allowing.
  defp target_types(%{"x-kiln-target-types" => [_ | _] = types}), do: types
  defp target_types(_schema), do: []

  defp open?(schema), do: Map.get(schema, "additionalProperties") != false

  # ── unions ──────────────────────────────────────────────────────────────────

  defp block_union(defs) do
    case Map.get(defs, @block_union) do
      %{"oneOf" => members} = schema ->
        tag = get_in(schema, ["discriminator", "propertyName"]) || "_type"

        %{
          name: @block_union,
          tag: tag,
          members:
            Enum.map(members, fn member ->
              name = member |> Map.get("$ref", "") |> ref_target()
              %{def: name, tag: tag_value(defs, name, tag)}
            end)
        }

      _ ->
        nil
    end
  end

  defp tag_value(defs, name, tag), do: get_in(defs, [name, "properties", tag, "const"])

  defp union?({_name, schema}), do: Map.has_key?(schema, "oneOf")

  defp def_kind(%{"oneOf" => _}), do: :union
  defp def_kind(%{"properties" => _}), do: :object
  defp def_kind(_schema), do: :opaque

  defp block_def?("block_" <> _), do: true
  defp block_def?(_), do: false

  defp content_def?(name), do: String.starts_with?(name, "content_")
end
