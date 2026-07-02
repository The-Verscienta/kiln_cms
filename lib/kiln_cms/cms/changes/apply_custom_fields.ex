defmodule KilnCMS.CMS.Changes.ApplyCustomFields do
  @moduledoc """
  Coerces and validates a content record's `custom_fields` map against the
  `FieldDefinition` registry for its content type (the admin-UI-defined schema).

  Runs on create and whenever `custom_fields` changes. For each defined field it
  coerces the supplied value (or the field's default) to the declared type,
  enforces `required`, and checks `:select` membership — then writes back a
  cleaned map containing only defined keys with JSON-native values (dates as
  ISO-8601 strings), so unknown/stale keys are dropped and the jsonb column
  round-trips cleanly. Definitions are read with `authorize?: false` (registry
  metadata, not user data).
  """
  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def change(changeset, _opts, _context) do
    if changeset.action_type == :create or
         Ash.Changeset.changing_attribute?(changeset, :custom_fields) do
      apply_definitions(changeset)
    else
      changeset
    end
  end

  defp apply_definitions(changeset) do
    defs = definitions_for(changeset)

    supplied = stringify_keys(Ash.Changeset.get_attribute(changeset, :custom_fields) || %{})

    {cleaned, errors} = Enum.reduce(defs, {%{}, []}, &accumulate(&1, supplied, &2))

    changeset
    |> Ash.Changeset.force_change_attribute(:custom_fields, cleaned)
    |> then(fn cs -> Enum.reduce(errors, cs, &Ash.Changeset.add_error(&2, &1)) end)
  end

  # The definitions in scope: a compiled content type's (by its type atom) or,
  # on the generic entry tier, the owning dynamic type's (by definition id —
  # nil while the entry is still invalid means simply no custom fields yet).
  defp definitions_for(%{resource: resource} = changeset) do
    if function_exported?(resource, :__kiln_dynamic_entry__, 0) do
      case Ash.Changeset.get_attribute(changeset, :type_definition_id) do
        nil -> []
        id -> KilnCMS.CMS.field_definitions_for_definition!(id, authorize?: false)
      end
    else
      KilnCMS.CMS.field_definitions_for!(resource.__kiln_content_type__(), authorize?: false)
    end
  end

  # Resolve one definition's value and fold it into the {cleaned, errors} acc.
  defp accumulate(def, supplied, {cleaned, errors}) do
    case resolve(def, supplied) do
      :skip -> {cleaned, errors}
      {:ok, value} -> {Map.put(cleaned, def.name, value), errors}
      {:error, message} -> {cleaned, [error(def, message) | errors]}
    end
  end

  # The coerced value for a definition: the supplied value (or its default),
  # `:skip` when blank-and-optional, or an error when blank-and-required.
  defp resolve(def, supplied) do
    raw = Map.get(supplied, def.name)
    raw = if blank?(raw), do: def.default, else: raw

    cond do
      blank?(raw) and def.required -> {:error, "is required"}
      blank?(raw) -> :skip
      true -> coerce(raw, def)
    end
  end

  # --- coercion to JSON-native values ----------------------------------------

  defp coerce(value, %{field_type: type}) when type in [:string, :text, :url] do
    {:ok, value |> to_string() |> String.trim()}
  end

  defp coerce(value, %{field_type: :select, options: options}) do
    str = value |> to_string() |> String.trim()
    if str in options, do: {:ok, str}, else: {:error, "is not one of the allowed options"}
  end

  defp coerce(value, %{field_type: :integer}) do
    case value do
      v when is_integer(v) -> {:ok, v}
      v -> parse(Integer, v, "must be a whole number")
    end
  end

  defp coerce(value, %{field_type: :float}) do
    case value do
      v when is_number(v) -> {:ok, v / 1}
      v -> parse(Float, v, "must be a number")
    end
  end

  defp coerce(value, %{field_type: :boolean}) do
    case value do
      v when is_boolean(v) -> {:ok, v}
      v when v in ["true", "1", "on"] -> {:ok, true}
      v when v in ["false", "0", "off", ""] -> {:ok, false}
      _ -> {:error, "must be a boolean"}
    end
  end

  defp coerce(value, %{field_type: :date}) do
    case Date.from_iso8601(to_string(value)) do
      {:ok, date} -> {:ok, Date.to_iso8601(date)}
      _ -> {:error, "must be a date (YYYY-MM-DD)"}
    end
  end

  defp coerce(value, %{field_type: :datetime}) do
    str = to_string(value)

    # Accept both full ISO-8601 and the HTML datetime-local shape (no seconds /
    # no offset), normalizing to an ISO-8601 string.
    with {:error, _} <- parse_datetime(str),
         {:error, _} <- parse_datetime(str <> ":00") do
      {:error, "must be a date and time"}
    end
  end

  # A media field: the editor submits a MediaItem id; the stored value is a
  # small snapshot (`%{"id", "url", "alt"}`) resolved at write time, so delivery
  # needs no extra lookup — the same embed-at-write-time stance image blocks
  # take. Re-saving refreshes the snapshot. Accepts a previously stored map too
  # (API writers may round-trip the stored shape).
  defp coerce(value, %{field_type: :media}) do
    with {:ok, id} <- extract_id(value),
         {:ok, media} <- KilnCMS.CMS.get_media_item(id, authorize?: false) do
      {:ok, %{"id" => media.id, "url" => media.url, "alt" => media.alt}}
    else
      _ -> {:error, "must be an existing media item"}
    end
  end

  # A content reference: resolves the target id against the field's declared
  # `target_type` (compiled or dynamic) and stores a snapshot
  # (`%{"id", "type", "slug", "title"}`) — id/type are the stable keys
  # consumers fetch fresh content with; slug/title are display labels that may
  # go stale until the next save.
  defp coerce(value, %{field_type: :reference, target_type: target}) do
    with {:ok, id} <- extract_id(value),
         ct when not is_nil(ct) <- KilnCMS.CMS.ContentTypes.get(target),
         {:ok, record} <- KilnCMS.CMS.ContentTypes.get_record(ct, id, authorize?: false) do
      {:ok,
       %{"id" => record.id, "type" => target, "slug" => record.slug, "title" => record.title}}
    else
      _ -> {:error, "must be an existing #{target || "content"} record"}
    end
  end

  defp extract_id(%{"id" => id}) when is_binary(id) and id != "", do: {:ok, id}
  defp extract_id(id) when is_binary(id), do: {:ok, id}
  defp extract_id(_other), do: :error

  defp parse_datetime(str) do
    case NaiveDateTime.from_iso8601(str) do
      {:ok, ndt} -> {:ok, NaiveDateTime.to_iso8601(ndt)}
      error -> error
    end
  end

  defp parse(mod, value, message) do
    case mod.parse(to_string(value)) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, message}
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp blank?(value), do: value in [nil, ""] or (is_binary(value) and String.trim(value) == "")

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp error(def, message) do
    InvalidAttribute.exception(
      field: :custom_fields,
      message: "#{def.label} (#{def.name}) #{message}",
      value: def.name
    )
  end
end
