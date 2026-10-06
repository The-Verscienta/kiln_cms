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

  What a value contributes, by default:

    * a string, its text — HTML tags and comments stripped and entities
      decoded (`KilnCMS.PlainText.from_html/1`), since a rich-text field
      stores markup and neither the snippet nor the embedding should read
      it;
    * a number, its decimal text;
    * a list or a map (a list of `{"language", "name"}` pairs, a snapshot),
      the strings and numbers inside it, depth first — map *keys* are not
      text anyone searches for, and an `"id"` is not either;
    * anything else (a boolean, `nil`), nothing.

  A project can read its own fields differently — decode JSON stored as
  text, keep only some keys of a structured value, order the fields — with
  a `KilnCMS.CMS.SearchableFields.Extractor` in config.

  `custom_fields` is `public?` as a whole and search reads run under the
  record's own read policy, so a searchable value is never shown to a reader
  who could not already read the record that holds it.
  """

  alias KilnCMS.CMS.Changes.ApplyCustomFields

  require Logger

  @doc """
  The searchable text of `custom_fields` under `definitions`, in the
  definitions' order — `[]` when no definition is flagged.
  """
  @spec texts(map() | nil, [KilnCMS.CMS.FieldDefinition.t()]) :: [String.t()]
  def texts(custom_fields, definitions) when is_map(custom_fields) do
    extractor = extractor()

    definitions
    |> Enum.filter(&Map.get(&1, :searchable, false))
    |> order(extractor)
    |> Enum.flat_map(fn definition ->
      field_texts(extractor, definition, Map.get(custom_fields, definition.name))
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

  @doc """
  The generic rule for one value: its strings (HTML stripped) and numbers,
  depth first, skipping map keys and `"id"`s — what a field contributes
  when no extractor is configured, or when the extractor answers `:default`.
  Public so an extractor can apply it to a value it decoded itself.
  """
  @spec default_texts(term()) :: [String.t()]
  def default_texts(value), do: value |> strings([]) |> Enum.reverse()

  # The configured `KilnCMS.CMS.SearchableFields.Extractor`, if any. Read at
  # runtime: a project sets it in its own config, after this module compiled.
  defp extractor do
    :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(:extractor)
  end

  defp order(definitions, extractor) do
    sorted = Enum.sort_by(definitions, & &1.position)

    # `Code.ensure_loaded?/1` first: `function_exported?/3` is false for a
    # module that has not been loaded yet, which in interactive mode (dev,
    # tests, an IEx session) is any extractor before its first call — so the
    # first indexing write after boot would silently use the editor order.
    if extractor && Code.ensure_loaded?(extractor) &&
         function_exported?(extractor, :order, 1) do
      extractor
      |> guarded(:order, fn -> extractor.order(sorted) end, sorted)
      |> checked_order(sorted, extractor)
    else
      sorted
    end
  end

  # What `order/1` returned, held to being an ordering of what it was given:
  # a definition it invented is dropped, a duplicate counts once, and one it
  # left out is appended in editor order rather than losing its text.
  defp checked_order(ordered, sorted, extractor) when is_list(ordered) do
    given = MapSet.new(sorted)
    kept = ordered |> Enum.filter(&MapSet.member?(given, &1)) |> Enum.uniq()

    if length(kept) != length(ordered) or length(kept) != length(sorted) do
      warn_once(extractor, :order, "returned an ordering that is not of its input; corrected")
    end

    kept ++ Enum.reject(sorted, &(&1 in kept))
  end

  defp checked_order(_other, sorted, extractor) do
    warn_once(extractor, :order, "returned a non-list; using the editor order")
    sorted
  end

  defp field_texts(nil, _definition, value), do: default_texts(value)

  defp field_texts(extractor, definition, value) do
    case guarded(
           extractor,
           definition.name,
           fn -> extractor.texts(definition, value) end,
           :default
         ) do
      :default ->
        default_texts(value)

      texts when is_list(texts) ->
        texts |> Enum.filter(&is_binary/1) |> Enum.flat_map(&default_texts/1)

      _other ->
        warn_once(extractor, definition.name, "returned neither a list nor :default")
        default_texts(value)
    end
  end

  # An extractor runs inside every indexing write: a bug in it — a raise, a
  # throw or an exit — must cost a field's text, never the editor's save.
  defp guarded(extractor, what, fun, fallback) do
    fun.()
  catch
    kind, reason ->
      warn_once(
        extractor,
        what,
        "failed (#{Exception.format_banner(kind, reason)}); using the default"
      )

      fallback
  end

  # Once per {extractor, field} per node: a broken extractor is otherwise one
  # warning per field per write, and a type-wide re-index writes every
  # published document. `:persistent_term` is written at most once per key
  # (its writes are expensive, its reads are not); the set of keys is bounded
  # by the configured extractor's fields.
  defp warn_once(extractor, what, message) do
    key = {__MODULE__, :warned, extractor, what}

    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)

      Logger.warning(
        "searchable fields: #{inspect(extractor)} #{message} for #{inspect(what)} " <>
          "(logged once per field until restart)"
      )
    end

    :ok
  end

  defp strings(value, acc) when is_binary(value) do
    case KilnCMS.PlainText.from_html(value) do
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
