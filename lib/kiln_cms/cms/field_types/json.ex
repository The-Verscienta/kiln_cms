defmodule KilnCMS.CMS.FieldTypes.Json do
  @moduledoc """
  A **JSON** custom field (#2278): an arbitrary JSON object or array, stored as
  that structure.

  Accepted input is a JSON text (the editor's textarea) or an already-decoded
  map or list (an API client). A bare scalar is refused: a number or a string
  has a proper field type of its own.

  The value is bounded, because it is stored in the content row and served on
  every delivery: at most 64 KB once re-encoded, 32 levels deep and 5,000
  values. The limits are enforced on the decoded term, so a deeply nested or
  very wide document is refused with a message rather than stored or crashing.

  A string or key containing a NUL character is refused: Postgres `jsonb`
  cannot store `\\u0000`.

  JSON fields cannot be filtered (other than for presence) or sorted, and are
  served through GraphQL as the generic JSON value. If an admin flags one
  `searchable`, the generic rule of `KilnCMS.CMS.SearchableFields` indexes the
  strings and numbers nested in the value (not its keys), so only flag a
  field whose contents are prose worth finding.
  """
  use Kiln.FieldType
  use Gettext, backend: KilnCMSWeb.Gettext

  @max_bytes 65_536
  # The text is decoded before it can be measured, so it gets its own, looser,
  # bound: pretty-printing can double what the re-encoded value takes.
  @max_input_bytes @max_bytes * 4
  @max_depth 32
  @max_nodes 5_000

  @impl Kiln.FieldType
  def label, do: "JSON"

  @impl Kiln.FieldType
  def description do
    gettext(
      "A JSON object or list, up to 64 KB. For structured data from another system that has no field of its own. Cannot be filtered or sorted."
    )
  end

  @impl Kiln.FieldType
  def graphql_kind(_definition), do: :json

  @impl Kiln.FieldType
  def json_schema(_definition), do: %{"type" => ["object", "array", "null"]}

  @impl Kiln.FieldType
  def cast(value, _definition) when is_binary(value) do
    with true <- byte_size(value) <= @max_input_bytes and String.valid?(value),
         {:ok, decoded} <- Jason.decode(value) do
      cast(decoded, nil)
    else
      false -> {:error, "must be valid JSON of at most #{div(@max_bytes, 1024)} KB"}
      {:error, _decode_error} -> {:error, "must be valid JSON"}
    end
  end

  def cast(value, _definition) when is_list(value) or (is_map(value) and not is_struct(value)) do
    with {:ok, normalized, _budget} <- normalize(value, 1, @max_nodes),
         true <- byte_size(Jason.encode!(normalized)) <= @max_bytes do
      {:ok, normalized}
    else
      :too_deep -> {:error, "is nested more than #{@max_depth} levels deep"}
      :too_many -> {:error, "has more than #{@max_nodes} values"}
      false -> {:error, "must be at most #{div(@max_bytes, 1024)} KB"}
      :error -> {:error, "must be valid JSON"}
    end
  end

  def cast(_value, _definition), do: {:error, "must be a JSON object or array"}

  # Walks the term once, counting values and depth (so a bomb stops at the
  # limit, not at the bottom), and returns it with atom keys as strings. Anything
  # that is not JSON data (a tuple, a pid, a struct) is `:error`.
  defp normalize(_term, _depth, budget) when budget <= 0, do: :too_many

  defp normalize(list, depth, budget) when is_list(list) do
    if depth > @max_depth do
      :too_deep
    else
      reduce(list, [], budget - 1, fn item, budget -> normalize(item, depth + 1, budget) end)
      |> reversed()
    end
  end

  defp normalize(map, depth, budget) when is_map(map) and not is_struct(map) do
    if depth > @max_depth do
      :too_deep
    else
      normalize_pairs(map, depth, budget)
    end
  end

  defp normalize(value, _depth, budget) when is_binary(value),
    do: if(clean?(value), do: {:ok, value, budget - 1}, else: :error)

  defp normalize(value, _depth, budget)
       when is_number(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value, budget - 1}

  defp normalize(_value, _depth, _budget), do: :error

  defp normalize_pairs(map, depth, budget) do
    map
    |> Enum.to_list()
    |> reduce([], budget - 1, fn {key, item}, budget ->
      with {:ok, key} <- key(key),
           {:ok, item, budget} <- normalize(item, depth + 1, budget) do
        {:ok, {key, item}, budget}
      end
    end)
    |> case do
      {:ok, pairs, budget} -> {:ok, Map.new(pairs), budget}
      other -> other
    end
  end

  defp key(key) when is_binary(key), do: if(clean?(key), do: {:ok, key}, else: :error)

  defp key(key) when is_atom(key) and not is_nil(key) and not is_boolean(key),
    do: {:ok, Atom.to_string(key)}

  defp key(_key), do: :error

  # Valid UTF-8 without NUL, which `jsonb` refuses.
  defp clean?(text), do: String.valid?(text) and not String.contains?(text, <<0>>)

  defp reduce([], acc, budget, _fun), do: {:ok, acc, budget}
  # An improper list (`[1 | 2]`) is not JSON.
  defp reduce([_ | _] = items, _acc, _budget, _fun) when not is_list(tl(items)), do: :error

  defp reduce([item | rest], acc, budget, fun) do
    case fun.(item, budget) do
      {:ok, normalized, budget} -> reduce(rest, [normalized | acc], budget, fun)
      other -> other
    end
  end

  defp reversed({:ok, items, budget}), do: {:ok, Enum.reverse(items), budget}
  defp reversed(other), do: other
end
