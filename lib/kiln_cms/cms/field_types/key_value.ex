defmodule KilnCMS.CMS.FieldTypes.KeyValue do
  @moduledoc """
  A **key/value** custom field (#2278): an ordered list of named values, for
  specifications, attributes or settings that vary by record ("Weight" =
  "2 kg").

  Stored as a list of pairs, `[%{"key" => "Weight", "value" => "2 kg"}, ...]`,
  not as one object: a `jsonb` object does not keep its keys in order, and the
  order is the editor's.

  Accepted input:

    * the editor's textarea: one `key=value` per line, split at the first
      `=` (so a value may contain `=`); blank lines are skipped;
    * a list of `%{"key", "value"}` maps (atom or string keys), order kept;
    * a plain map of text to text, a convenience for an API client; the pairs
      are stored sorted by key.

  Keys and values are trimmed. Limits: at most 100 pairs; a key of 1 to 100
  characters; a value of up to 1,000; keys unique (case-sensitive); 64 KB in
  all once encoded. Both are text on a single line: a `=` in a key, a line
  break, a NUL character or invalid UTF-8 is refused, so what is stored is
  always what the textarea can show and re-submit. A pair with neither key nor
  value is dropped, and a field left with no pairs is empty (not stored).

  Not filterable (other than for presence) or sortable; served through GraphQL
  as the generic JSON value. If an admin flags one `searchable`, the *values*
  are indexed (not the keys).
  """
  use Kiln.FieldType
  use Gettext, backend: KilnCMSWeb.Gettext

  @max_pairs 100
  @max_key 100
  @max_value 1_000
  @max_bytes 65_536

  @impl Kiln.FieldType
  def label, do: "Key/value list"

  @impl Kiln.FieldType
  def description do
    gettext(
      "An ordered list of named values, one key=value per line. For specifications or attributes that vary by record. Cannot be filtered or sorted."
    )
  end

  @impl Kiln.FieldType
  def graphql_kind(_definition), do: :json

  @impl Kiln.FieldType
  def json_schema(_definition) do
    %{
      "type" => ["array", "null"],
      "maxItems" => @max_pairs,
      "items" => %{
        "type" => "object",
        "required" => ["key", "value"],
        "properties" => %{
          "key" => %{"type" => "string", "minLength" => 1, "maxLength" => @max_key},
          "value" => %{"type" => "string", "maxLength" => @max_value}
        },
        "additionalProperties" => false
      }
    }
  end

  @impl Kiln.FieldType
  def cast(value, _definition) when is_binary(value) do
    if byte_size(value) <= @max_bytes * 2 and String.valid?(value) do
      value
      |> String.split(["\r\n", "\n", "\r"])
      |> collect(&split_line/1)
    else
      {:error, "must be valid text of at most #{div(@max_bytes, 1024)} KB"}
    end
  end

  def cast(value, _definition) when is_list(value), do: collect(value, &pair/1)

  def cast(value, _definition) when is_map(value) and not is_struct(value) do
    value
    |> Enum.map(fn {key, item} -> %{"key" => text_key(key), "value" => item} end)
    |> collect(&pair/1)
    |> case do
      {:ok, pairs} -> {:ok, Enum.sort_by(pairs, & &1["key"])}
      error -> error
    end
  end

  def cast(_value, _definition),
    do: {:error, "must be a list of key=value pairs"}

  defp text_key(key) when is_binary(key), do: key

  defp text_key(key) when is_atom(key) and not is_nil(key) and not is_boolean(key),
    do: Atom.to_string(key)

  defp text_key(key), do: key

  # Folds `fun` over `items`, keeping its pairs (newest first, for `finish/1`),
  # skipping blanks and stopping at the first refusal.
  defp collect(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        :blank -> {:cont, {:ok, acc}}
        {:ok, pair} -> {:cont, {:ok, [pair | acc]}}
        :error -> {:halt, {:error, "each line must be key=value"}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> finish()
  end

  defp split_line(line) do
    case String.split(line, "=", parts: 2) do
      [only] -> if String.trim(only) == "", do: :blank, else: :error
      [key, value] -> pair(%{"key" => key, "value" => value})
    end
  end

  defp pair(%{} = item) when not is_struct(item) do
    key = Map.get(item, "key", Map.get(item, :key))
    value = Map.get(item, "value", Map.get(item, :value))

    cond do
      Map.keys(item) -- ["key", "value", :key, :value] != [] ->
        {:error, "each pair may only have a key and a value"}

      not text?(key) or not (text?(value) or is_nil(value)) ->
        {:error, "keys and values must be text"}

      true ->
        key = String.trim(key)
        value = String.trim(value || "")
        validated(key, value)
    end
  end

  defp pair(_item), do: {:error, "each pair must have a key and a value"}

  defp text?(value), do: is_binary(value)

  defp validated("", ""), do: :blank
  defp validated("", _value), do: {:error, "every value needs a key"}

  defp validated(key, value) do
    cond do
      not (clean?(key) and clean?(value)) ->
        {:error, "keys and values must be single-line text"}

      String.contains?(key, "=") ->
        {:error, "a key may not contain \"=\""}

      String.length(key) > @max_key ->
        {:error, "a key is at most #{@max_key} characters"}

      String.length(value) > @max_value ->
        {:error, "a value is at most #{@max_value} characters"}

      true ->
        {:ok, %{"key" => key, "value" => value}}
    end
  end

  # Valid UTF-8, no NUL (`jsonb` cannot store it) and no line break or other
  # control character, which the textarea could not carry.
  defp clean?(text),
    do: String.valid?(text) and not String.match?(text, ~r/[\x00-\x1F\x7F]/u)

  defp finish({:error, _} = error), do: error

  defp finish({:ok, reversed}) do
    pairs = Enum.reverse(reversed)
    keys = Enum.map(pairs, & &1["key"])

    cond do
      pairs == [] ->
        {:error, "needs at least one key=value pair"}

      length(pairs) > @max_pairs ->
        {:error, "has more than #{@max_pairs} pairs"}

      length(Enum.uniq(keys)) != length(keys) ->
        {:error, "has a repeated key (#{Enum.at(keys -- Enum.uniq(keys), 0)})"}

      byte_size(Jason.encode!(pairs)) > @max_bytes ->
        {:error, "must be at most #{div(@max_bytes, 1024)} KB"}

      true ->
        {:ok, pairs}
    end
  end
end
