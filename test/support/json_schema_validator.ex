defmodule KilnCMS.JsonSchemaValidator do
  @moduledoc """
  A deliberately small JSON Schema validator, for asserting that Kiln's own
  exported schema (#430) describes Kiln's own output.

  Test-only, and not a general-purpose implementation: it covers exactly the
  keywords `KilnCMS.SchemaExport` emits — `$ref`, `oneOf`, `const`, `enum`,
  `type` (including type arrays), `properties`, `required`, `items`,
  `additionalProperties: false`. Anything else is treated as satisfied.

  Pulling in a real validator would be the honest choice for validating
  *arbitrary* schemas; for validating one schema we generate ourselves, a
  hundred lines with no dependency is the better trade — and a keyword this
  does not implement is a keyword we do not emit.
  """

  @doc """
  Validate `value` against `schema`, resolving `$ref` inside `root`
  (defaulting to `schema` itself).

  Returns `:ok` or `{:error, [message]}`, where each message names the failing
  JSON pointer so a failure says *which* block's *which* field was wrong.
  """
  @spec validate(term(), map(), map() | nil) :: :ok | {:error, [String.t()]}
  def validate(value, schema, root \\ nil) do
    case check(value, schema, root || schema, "#") do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  # An unresolvable pointer is an **error**, never an empty schema. `%{}` accepts
  # anything, so a dangling `$ref` would not just pass — inside `oneOf` it would
  # become the one matching branch, and the artifact test whose whole job is
  # catching export/render drift would go green on arbitrary garbage.
  defp check(value, %{"$ref" => "#/$defs/" <> name}, root, path) do
    case get_in(root, ["$defs", name]) do
      nil -> ["#{path}: unresolvable $ref #/$defs/#{name}"]
      target -> check(value, target, root, path)
    end
  end

  defp check(_value, %{"$ref" => ref}, _root, path),
    do: ["#{path}: unsupported $ref #{ref}"]

  # `oneOf` is checked *alongside* its siblings, not instead of them: a schema
  # carrying `oneOf` plus `required`/`additionalProperties` must satisfy all of
  # them, and discarding the siblings made the root document — which is exactly
  # that shape — accept anything.
  defp check(value, %{"oneOf" => branches} = schema, root, path) do
    matching = Enum.count(branches, &(check(value, &1, root, path) == []))

    one_of =
      case matching do
        1 -> []
        0 -> ["#{path}: matched none of the #{length(branches)} oneOf branches"]
        n -> ["#{path}: matched #{n} oneOf branches, expected exactly one"]
      end

    one_of ++ check(value, Map.delete(schema, "oneOf"), root, path)
  end

  defp check(value, schema, root, path) do
    Enum.flat_map(schema, fn
      {"const", expected} when value != expected ->
        ["#{path}: expected const #{inspect(expected)}, got #{inspect(value)}"]

      {"enum", allowed} ->
        if value in allowed,
          do: [],
          else: ["#{path}: #{inspect(value)} not in #{inspect(allowed)}"]

      {"type", types} ->
        types = List.wrap(types)

        if Enum.any?(types, &type_matches?(value, &1)),
          do: [],
          else: ["#{path}: #{inspect(value)} is not #{Enum.join(types, " | ")}"]

      {"required", keys} when is_map(value) ->
        for key <- keys, not Map.has_key?(value, key), do: "#{path}: missing required #{key}"

      {"properties", properties} when is_map(value) ->
        Enum.flat_map(value, &check_property(&1, properties, root, path))

      {"additionalProperties", false} when is_map(value) ->
        declared = schema |> Map.get("properties", %{}) |> Map.keys() |> MapSet.new()

        for key <- Map.keys(value),
            not MapSet.member?(declared, key),
            do: "#{path}: undeclared property #{key}"

      {"items", item_schema} when is_list(value) ->
        value
        |> Enum.with_index()
        |> Enum.flat_map(fn {item, i} -> check(item, item_schema, root, "#{path}/#{i}") end)

      _ ->
        []
    end)
  end

  # A key with no declared schema is unconstrained here; `additionalProperties`
  # is what decides whether it is allowed at all.
  defp check_property({key, member}, properties, root, path) do
    case Map.get(properties, key) do
      nil -> []
      schema -> check(member, schema, root, "#{path}/#{key}")
    end
  end

  defp type_matches?(nil, "null"), do: true
  defp type_matches?(value, "string"), do: is_binary(value)
  defp type_matches?(value, "boolean"), do: is_boolean(value)
  defp type_matches?(value, "integer"), do: is_integer(value)
  defp type_matches?(value, "number"), do: is_number(value)
  defp type_matches?(value, "array"), do: is_list(value)
  defp type_matches?(value, "object"), do: is_map(value) and not is_struct(value)
  defp type_matches?(_value, _type), do: false
end
