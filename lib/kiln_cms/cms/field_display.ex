defmodule KilnCMS.CMS.FieldDisplay do
  @moduledoc """
  How a custom-field value reads in a history surface (#2294): the version
  compare modal today.

  The stored value is the wrong thing to show an editor. A `:select` stores
  the option, not its label; a `:media` or `:reference` stores a snapshot map
  (or a bare id, once the snapshot is stripped); a `:group` stores a nested
  object keyed by sub-field names. `display/3` turns one value into a bounded
  string, given the field's `KilnCMS.CMS.FieldDefinition`:

    * `:select` (single or `multiple`) shows the option labels;
    * `:media` and `:reference` show the target's current filename / title,
      or the **raw id** when the reader cannot read the target (a draft they
      may not see, a trashed or deleted record). The id is what was stored, so
      it is never wrong, and it never leaks a title the reader may not read;
    * a rich `:text` field has its tags stripped;
    * a `:group` shows `Label: value` pairs, a bounded number of rows and
      sub-fields;
    * anything else, and any value whose definition is gone (a retired field),
      falls back to `format/1`, the generic compact rendering.

  Targets are resolved by `context/4`, once per diff: one read for every media
  item and one batched read per content type for every reference the diff
  names, never one per row. Both reads carry the **actor and tenant**, so the
  reader's own policies decide what is readable; there is no
  `authorize?: false` here.
  """
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Checks.LinkEndsReadable
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.CMS.VersionDiff
  alias KilnCMS.PlainText

  @typedoc "Resolved targets: `media`/`refs` map a target id to its display label."
  @type context :: %{media: %{String.t() => String.t()}, refs: %{String.t() => String.t()}}

  @value_limit 200
  @max_rows 3
  @max_group_fields 8
  @max_items 10
  @max_depth 2

  @doc "A context that resolves nothing: every media and reference value shows its raw id."
  @spec empty_context() :: context()
  def empty_context, do: %{media: %{}, refs: %{}}

  @doc """
  Resolves the media items and reference targets the `custom_fields` row of
  `diff` names, as `actor` in `org_id`. `definitions` is the list of field
  definitions in scope.

  A target `actor` cannot read is absent from the result, so `display/3` falls
  back to its id. A failed read is the same as an unreadable one.
  """
  @spec context([struct()], VersionDiff.t(), term(), Ash.UUID.t() | nil) :: context()
  def context(definitions, %VersionDiff{} = diff, actor, org_id) do
    by_name = Map.new(definitions, &{&1.name, &1})

    values =
      for %VersionDiff.Field{name: :custom_fields, entries: entries} <- diff.fields,
          entry <- entries,
          side <- [entry.old, entry.new],
          not is_nil(side),
          do: {Map.get(by_name, entry.key), side}

    {media_ids, ref_ids} =
      Enum.reduce(values, {[], []}, fn {definition, value}, acc ->
        collect(definition, value, acc, 0)
      end)

    %{
      media: media_labels(Enum.uniq(media_ids), actor, org_id),
      refs: reference_labels(Enum.uniq(ref_ids), actor, org_id)
    }
  end

  @doc """
  The display string for `value` of the field `definition` describes.

  `definition` is `nil` for a field with no definition (retired, renamed or
  deleted since the version was saved); the value then reads generically.
  """
  @spec display(struct() | nil, term(), context()) :: String.t()
  def display(definition, value, context), do: display(definition, value, context, 0)

  @doc """
  The generic rendering: strings as written, scalars as text, structures as
  compact JSON. Always truncated, because a stored value is the editor's own
  content echoed back into the page.
  """
  @spec format(term()) :: String.t()
  def format(value) when is_binary(value), do: truncate(value)
  def format(value) when is_number(value), do: to_string(value)
  def format(value) when is_boolean(value), do: to_string(value)

  def format(value) do
    truncate(Jason.encode!(value))
  rescue
    _error -> truncate(inspect(value))
  end

  # ── Rendering ─────────────────────────────────────────────────────────────

  defp display(nil, value, _context, _depth), do: format(value)

  defp display(%{field_type: :select} = definition, value, _context, _depth) do
    value
    |> List.wrap()
    |> Enum.map_join(", ", fn
      option when is_binary(option) -> FieldDefinition.option_label(definition, option)
      other -> format(other)
    end)
    |> truncate()
  end

  defp display(%{field_type: :media}, value, context, _depth),
    do: items(value, &media_text(&1, context))

  defp display(%{field_type: :reference}, value, context, _depth),
    do: items(value, &reference_text(&1, context))

  defp display(%{field_type: :text, format: :rich}, value, _context, _depth)
       when is_binary(value) do
    value
    |> PlainText.strip_tags()
    |> PlainText.decode_entities()
    |> String.split()
    |> Enum.join(" ")
    |> truncate()
  end

  defp display(%{field_type: :group} = definition, value, context, depth) do
    rows = value |> List.wrap() |> Enum.filter(&is_map/1)
    sub_fields = sub_definitions(definition)

    if rows == [] or depth >= @max_depth do
      format(value)
    else
      shown = rows |> Enum.take(@max_rows) |> Enum.map(&row_text(&1, sub_fields, context, depth))
      more = length(rows) - @max_rows
      suffix = if more > 0, do: ["+#{more}"], else: []

      shown |> Kernel.++(suffix) |> Enum.join(" | ") |> truncate()
    end
  end

  defp display(_definition, value, _context, _depth), do: format(value)

  defp row_text(row, sub_fields, context, depth) do
    by_name = Map.new(sub_fields, &{&1.name, &1})

    ordered =
      Enum.filter(sub_fields, &Map.has_key?(row, &1.name)) ++
        for {key, _value} <- Enum.sort(row), not Map.has_key?(by_name, key), do: key

    ordered
    |> Enum.take(@max_group_fields)
    |> Enum.reject(&blank?(row_value(row, &1)))
    |> Enum.map_join("; ", fn
      %{name: name, label: label} = sub ->
        "#{label || name}: #{display(sub, Map.get(row, name), context, depth + 1)}"

      key ->
        "#{key}: #{format(Map.get(row, key))}"
    end)
  end

  defp row_value(row, %{name: name}), do: Map.get(row, name)
  defp row_value(row, key), do: Map.get(row, key)

  defp items(value, fun) do
    list = List.wrap(value)
    shown = list |> Enum.take(@max_items) |> Enum.map_join(", ", fun)
    more = length(list) - @max_items

    truncate(if more > 0, do: "#{shown}, +#{more}", else: shown)
  end

  defp media_text(%{"id" => id}, context) when is_binary(id), do: Map.get(context.media, id, id)
  defp media_text(id, context) when is_binary(id), do: Map.get(context.media, id, id)
  defp media_text(other, _context), do: format(other)

  defp reference_text(%{"id" => id}, context) when is_binary(id),
    do: Map.get(context.refs, id, id)

  defp reference_text(id, context) when is_binary(id), do: Map.get(context.refs, id, id)
  defp reference_text(other, _context), do: format(other)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(_value), do: false

  defp truncate(text) when byte_size(text) <= @value_limit, do: text
  defp truncate(text), do: String.slice(text, 0, @value_limit) <> "…"

  # ── Target resolution ─────────────────────────────────────────────────────

  # Walks a value by its definition, gathering the media and reference ids it
  # names. Depth-bounded like the rendering, so a malformed nest costs nothing.
  defp collect(%{field_type: :media}, value, {media, refs}, _depth),
    do: {target_ids(value) ++ media, refs}

  defp collect(%{field_type: :reference}, value, {media, refs}, _depth),
    do: {media, target_ids(value) ++ refs}

  defp collect(%{field_type: :group} = definition, value, acc, depth) when depth < @max_depth do
    sub_fields = Map.new(sub_definitions(definition), &{&1.name, &1})

    for row <- List.wrap(value),
        is_map(row),
        {key, sub_value} <- row,
        reduce: acc do
      acc -> collect(Map.get(sub_fields, key), sub_value, acc, depth + 1)
    end
  end

  defp collect(_definition, _value, acc, _depth), do: acc

  # Both stored shapes: the snapshot map (`KilnCMS.Media.Snapshot`,
  # `KilnCMS.CMS.ReferenceSnapshots`), or a bare id.
  defp target_ids(value) do
    value
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"id" => id} when is_binary(id) -> [id]
      id when is_binary(id) -> [id]
      _other -> []
    end)
    |> Enum.filter(&uuid?/1)
  end

  defp media_labels([], _actor, _org_id), do: %{}

  defp media_labels(ids, actor, org_id) do
    case CMS.list_media_items(
           actor: actor,
           tenant: org_id,
           query: [filter: [id: [in: ids]]]
         ) do
      {:ok, items} ->
        Map.new(items, &{&1.id, &1.filename || &1.alt || &1.id})

      {:error, _reason} ->
        %{}
    end
  end

  defp reference_labels([], _actor, _org_id), do: %{}

  defp reference_labels(ids, actor, org_id) do
    actor
    |> LinkEndsReadable.readable_labels(org_id, ids)
    |> Map.new(fn {id, label} -> {id, label["title"] || label["slug"] || id} end)
  end

  defp uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))

  defp sub_definitions(%{group_fields: fields}) when is_list(fields), do: fields
  defp sub_definitions(_definition), do: []
end
