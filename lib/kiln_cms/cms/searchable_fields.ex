defmodule KilnCMS.CMS.SearchableFields do
  @moduledoc """
  The text of a record's **searchable** custom fields — the ones whose
  `KilnCMS.CMS.FieldDefinition` an admin flagged `searchable: true` — for
  `KilnCMS.CMS.Changes.SetSearchText` to append to `search_text` (#1585).

  `custom_fields` was never indexed, so a record kept its identity fields —
  a Chinese name, a pinyin spelling, a Latin binomial, its common names —
  where full-text search could not see them, and was findable by one only
  where the body prose happened to repeat it. For a Han name, that was
  nowhere.

  Opt-in per field rather than the whole map: most keys are numbers, enums,
  dates and media or reference snapshots, which would only add noise to the
  vector, and some values are long. The values are appended after the body,
  as `B`-weight body words: a name that should rank like a title is what
  `names_record` (the alias leg) is for.

  What a value contributes:

    * a string, itself;
    * a number, its decimal text;
    * a list or a map (a list of `{"language", "name"}` pairs, a snapshot),
      the strings and numbers inside it, depth first — map *keys* are not
      text anyone searches for, and an `"id"` is not either;
    * anything else (a boolean, `nil`), nothing.

  `custom_fields` is `public?` as a whole and search reads run under the
  record's own read policy, so a searchable value is never shown to a reader
  who could not already read the record that holds it.
  """

  alias KilnCMS.CMS.Changes.ApplyCustomFields

  @doc """
  The searchable text of `custom_fields` under `definitions`, in the
  definitions' order — `[]` when no definition is flagged.
  """
  @spec texts(map() | nil, [KilnCMS.CMS.FieldDefinition.t()]) :: [String.t()]
  def texts(custom_fields, definitions) when is_map(custom_fields) do
    definitions
    |> Enum.filter(&Map.get(&1, :searchable, false))
    |> Enum.sort_by(& &1.position)
    |> Enum.flat_map(fn definition ->
      custom_fields |> Map.get(definition.name) |> strings() |> Enum.reverse()
    end)
  end

  def texts(_custom_fields, _definitions), do: []

  @doc """
  The searchable text of a loaded content `record`, reading its type's
  definitions — for a caller that holds a struct rather than a changeset
  (`KilnCMS.Firing.Engine`, via `SetSearchText.compute/2`). A record with no
  custom fields reads nothing.
  """
  @spec record_texts(struct()) :: [String.t()]
  def record_texts(%resource{} = record) do
    case Map.get(record, :custom_fields) do
      fields when is_map(fields) and map_size(fields) > 0 ->
        definitions =
          ApplyCustomFields.definitions(
            resource,
            Map.get(record, :type_definition_id),
            Map.get(record, :org_id)
          )

        texts(fields, definitions)

      _none ->
        []
    end
  end

  def record_texts(_record), do: []

  defp strings(value), do: strings(value, [])

  defp strings(value, acc) when is_binary(value) do
    case String.trim(value) do
      "" -> acc
      text -> [text | acc]
    end
  end

  defp strings(value, acc) when is_integer(value) or is_float(value),
    do: [to_string(value) | acc]

  defp strings(values, acc) when is_list(values), do: Enum.reduce(values, acc, &strings/2)

  defp strings(%{} = map, acc) when not is_struct(map) do
    map
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reject(fn {key, _value} -> to_string(key) == "id" end)
    |> Enum.reduce(acc, fn {_key, value}, acc -> strings(value, acc) end)
  end

  defp strings(_other, acc), do: acc
end
