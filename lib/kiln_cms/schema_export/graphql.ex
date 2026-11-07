defmodule KilnCMS.SchemaExport.GraphQL do
  @moduledoc """
  What the typed-GraphQL sections of the TypeScript, Swift and Kotlin emitters
  (#2290) share, so they cannot disagree about it.

  The GraphQL schema is the same for every site, so a custom field cannot be a
  GraphQL field of its own. It is read through an **accessor** chosen by the
  field's kind (the `x-kiln-graphql-kind` annotation of
  `KilnCMS.SchemaExport.json_schema(graphql: true)`, i.e. what
  `KilnCMS.CMS.FieldKind` decides):

    * a string, integer, float, boolean, date or datetime field is read as an
      alias of its scalar accessor (`price: customFloat(name: "price")`) and
      typed per language;
    * every other kind is read, together, through `fields(names: [...])`, which
      returns `CustomFieldValue`s narrowed on `__typename`.

  This module owns the part that is the same in every language: which types get
  a section, the alias each scalar field is read under (and the collision
  rules), and the text of the GraphQL fragment. A language spells the result
  type and embeds the fragment.
  """

  alias KilnCMS.SchemaExport.Walk

  # Reserved GraphQL names a custom field's alias must not shadow: the document's
  # own properties (camelized by AshGraphql) and the typed readers themselves.
  @reserved_aliases ~w(id title slug excerpt blocks type locale status audience customFields
                       customFieldsPlain customFieldsPortable fields typeName inheritedFields
                       seoTitle seoDescription seoKeywords pathAlias seoImage canonicalUrl
                       state published publishedAt insertedAt updatedAt references referencedBy
                       customString customInt customFloat customBoolean customDate customDateTime)

  @scalar_accessors %{
    "string" => "customString",
    "int" => "customInt",
    "float" => "customFloat",
    "boolean" => "customBoolean",
    "date" => "customDate",
    "datetime" => "customDateTime"
  }

  @typedoc """
  One content type's section. `scalars` and `others` are the custom fields
  (annotated, so readable over GraphQL), split by whether the kind has a scalar
  accessor; each scalar carries its `:alias`.
  """
  @type section :: %{
          decl: map(),
          base: String.t(),
          on: String.t(),
          type_name: String.t() | nil,
          scalars: [map()],
          others: [map()]
        }

  @doc "The accessor for a scalar GraphQL kind: `float` is read by `customFloat`, `int` by `customInt`."
  @spec accessor(String.t()) :: String.t()
  def accessor(kind), do: Map.fetch!(@scalar_accessors, kind)

  @doc """
  The sections for a walked model, one per content type that has a GraphQL type
  and at least one readable custom field (an empty selection set is not valid
  GraphQL). `base_name` turns the `$defs` name (`content_post`) into the base
  the language names its types from.
  """
  @spec types(Walk.model(), (String.t() -> String.t())) :: [section()]
  def types(model, base_name) do
    model.documents
    |> Enum.filter(& &1.graphql)
    |> Enum.map(fn decl -> {decl, custom_fields(decl)} end)
    |> Enum.reject(fn {_decl, custom} -> custom == [] end)
    |> Enum.map(fn {decl, custom} ->
      {scalars, others} =
        Enum.split_with(custom, &Map.has_key?(@scalar_accessors, &1.graphql_kind))

      %{
        decl: decl,
        base: base_name.(decl.name),
        on: decl.graphql["type"],
        type_name: decl.graphql["type_name"],
        scalars: put_aliases(scalars),
        others: others
      }
    end)
  end

  @doc """
  The named GraphQL fragment `name` on the section's type, as text (no trailing
  newline).
  """
  @spec fragment(String.t(), section()) :: String.t()
  def fragment(name, %{on: on, scalars: scalars, others: others}) do
    selection =
      Enum.map(scalars, fn field ->
        "  #{field.alias}: #{accessor(field.graphql_kind)}(name: #{inspect(field.key)})"
      end) ++ fields_selection(others)

    "fragment #{name} on #{on} {\n#{Enum.join(selection, "\n")}\n}"
  end

  defp custom_fields(decl) do
    case Enum.find(elem(decl.shape, 1), &(&1.key == "custom_fields")) do
      %{type: {:object, fields, _open?}} -> Enum.filter(fields, & &1.graphql_kind)
      _other -> []
    end
  end

  # Aliases must be unique within one fragment: `Macro.camelize/1` is not
  # injective (`foo_bar` and `foo__bar` both give `fooBar`), so a taken alias
  # gets a numeric suffix.
  defp put_aliases(fields) do
    {fields, _taken} =
      Enum.map_reduce(fields, MapSet.new(), fn field, taken ->
        base = field_alias(field.key)

        alias_name =
          Enum.find(
            [base | Enum.map(2..1000, &"#{base}#{&1}")],
            &(not MapSet.member?(taken, &1))
          )

        {Map.put(field, :alias, alias_name), MapSet.put(taken, alias_name)}
      end)

    fields
  end

  # Every field name is `[a-z][a-z0-9_]*` (`FieldDefinition`), a valid GraphQL name.
  defp field_alias(key) do
    <<first::utf8, rest::binary>> = Macro.camelize(key)
    camel = String.downcase(<<first::utf8>>) <> rest

    if camel in @reserved_aliases, do: "custom" <> Macro.camelize(key), else: camel
  end

  defp fields_selection([]), do: []

  defp fields_selection(others) do
    names = Enum.map_join(others, ", ", &inspect(&1.key))

    ["  fields(names: [#{names}]) {", value_selection(2), "  }"]
  end

  # The selection under `fields(names:)`, as lines already indented. One level
  # into lists and groups; a row of a repeating group is a `GroupValue` item.
  defp value_selection(indent) do
    items = ["... on ListValue {", "  items {"] ++ indent_lines(value_parts() ++ [group_row()], 4)
    group = ["... on GroupValue {", "  fields {"] ++ indent_lines(value_parts(), 4)

    (value_parts() ++ items ++ ["  }", "}"] ++ group ++ ["  }", "}"])
    |> indent_lines(indent * 2)
    |> Enum.join("\n")
  end

  defp indent_lines(lines, n), do: Enum.map(lines, &(String.duplicate(" ", n) <> &1))

  defp value_parts do
    ["__typename", "name"] ++ scalar_parts() ++ ["... on ReferenceValue { ids }", media_part()]
  end

  defp scalar_parts do
    [
      "... on StringValue { asString: value }",
      "... on IntValue { asInt: value }",
      "... on FloatValue { asFloat: value }",
      "... on BooleanValue { asBoolean: value }",
      "... on DateValue { asDate: value }",
      "... on DateTimeValue { asDateTime: value }",
      "... on GeolocationValue { lat lng label zoom }",
      "... on JsonValue { asJson: value }"
    ]
  end

  defp media_part,
    do:
      "... on MediaValue { id url alt width height mimeType focal { x y } " <>
        "variants { label width height format url bytes cropped } }"

  defp group_row,
    do: "... on GroupValue { fields { __typename name #{Enum.join(scalar_parts(), " ")} } }"
end
