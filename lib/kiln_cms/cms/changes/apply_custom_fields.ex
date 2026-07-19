defmodule KilnCMS.CMS.Changes.ApplyCustomFields do
  @moduledoc """
  Coerces and validates a content record's `custom_fields` map against the
  `FieldDefinition` registry for its content type (the admin-UI-defined schema).

  Runs on create and whenever `custom_fields` changes. For each defined field it
  coerces the supplied value (or the field's default) to the declared type,
  enforces `required`, and checks `:select` membership — then writes back a
  cleaned map containing only defined keys with JSON-native values (dates as
  ISO-8601 strings), so unknown/stale keys are dropped and the jsonb column
  round-trips cleanly. Types beyond the built-ins dispatch to their registered
  `Kiln.FieldType`'s `cast/2` (see `KilnCMS.CMS.FieldTypes`). Definitions are
  read with `authorize?: false` (registry metadata, not user data).

  ## Partial updates merge; the payload is not the whole record

  On **update**, the supplied map is merged over the record's existing
  `custom_fields` with three-way, per-key semantics:

    * a key **present with a value** is coerced and written;
    * a key **present but blank** is cleared (or reset to its default);
    * a key **absent** from the payload keeps its stored value untouched.

  So an API/MCP client can `PATCH` a single field without resending the rest —
  omitting a field no longer silently wipes it. On **create** there is nothing
  to merge over, so absent fields fall to their defaults as before.

  The form editor is unaffected: it renders an input for every definition and
  submits the complete map (blank for empties), so every key is "present" and
  clearing a field by emptying it still works exactly as before.
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

    # The writing org (epic #336). `:media`/`:reference` fields resolve a snapshot
    # by id under this tenant, so a value pointing at another site's media/content
    # simply won't resolve (nil under `global?: true` → a validation error rather
    # than a cross-org leak). Tenant-less writes (default org) resolve as before.
    tenant = changeset.to_tenant

    supplied = stringify_keys(Ash.Changeset.get_attribute(changeset, :custom_fields) || %{})

    # The base to merge the payload over. On create there is no record yet, so
    # absent fields fall to their defaults (empty base). On update we carry the
    # stored values forward, so a field the caller didn't mention is preserved
    # rather than dropped by the full-map rewrite below.
    existing =
      case changeset.action_type do
        :create -> %{}
        _ -> stringify_keys(changeset.data.custom_fields || %{})
      end

    {cleaned, errors} =
      Enum.reduce(defs, {%{}, []}, &accumulate(&1, supplied, existing, tenant, &2))

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
  # Three-way per key: a field the caller *supplied* is coerced/cleared; a field
  # they omitted keeps its `existing` stored value (the merge); a field with
  # neither falls to its default (fresh field / create).
  defp accumulate(def, supplied, existing, tenant, {cleaned, errors}) do
    cond do
      Map.has_key?(supplied, def.name) ->
        fold(resolve(def, Map.get(supplied, def.name), tenant), def, cleaned, errors)

      Map.has_key?(existing, def.name) ->
        # Untouched by this write: keep the stored (already-coerced) value as-is.
        # No re-coercion, so a stale reference/media snapshot isn't re-resolved
        # and a since-changed definition can't reject a value the caller never
        # sent.
        {Map.put(cleaned, def.name, Map.get(existing, def.name)), errors}

      true ->
        fold(resolve(def, nil, tenant), def, cleaned, errors)
    end
  end

  defp fold(:skip, _def, cleaned, errors), do: {cleaned, errors}
  defp fold({:ok, value}, def, cleaned, errors), do: {Map.put(cleaned, def.name, value), errors}

  defp fold({:error, message}, def, cleaned, errors),
    do: {cleaned, [error(def, message) | errors]}

  # The coerced value for a definition from a supplied `raw` (or its default):
  # `:skip` when blank-and-optional, or an error when blank-and-required.
  defp resolve(def, raw, tenant) do
    raw = if blank?(raw), do: def.default, else: raw

    cond do
      blank?(raw) and def.required -> {:error, "is required"}
      blank?(raw) -> :skip
      true -> coerce(raw, def, tenant)
    end
  end

  # Tenant-aware dispatch: only `:media`/`:reference` resolve records (and so need
  # the writing tenant); every other field type coerces purely from its value, so
  # it delegates to the type-only `coerce/2` below.
  defp coerce(value, %{field_type: :media} = def, tenant),
    do: coerce_media(value, def, tenant)

  defp coerce(value, %{field_type: :reference} = def, tenant),
    do: coerce_reference(value, def, tenant)

  defp coerce(value, def, _tenant), do: coerce(value, def)

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

  # A plugin-contributed field type (`Kiln.FieldType`): the plugin's `cast/2`
  # owns coercion + validation. The contract requires a JSON-native return —
  # anything else is a loud contract violation, not a swallowed write.
  defp coerce(value, %{field_type: type} = definition) do
    case KilnCMS.CMS.FieldTypes.get(type) do
      nil ->
        {:error, "has an unregistered field type"}

      module ->
        case module.cast(value, definition) do
          {:ok, cast} ->
            {:ok, cast}

          {:error, message} when is_binary(message) ->
            {:error, message}

          other ->
            raise "#{inspect(module)}.cast/2 must return {:ok, value} | {:error, message}, " <>
                    "got: #{inspect(other)}"
        end
    end
  end

  # A media field: the editor submits a MediaItem id; the stored value is a
  # small snapshot (`%{"id", "url", "alt"}`) resolved at write time, so delivery
  # needs no extra lookup — the same embed-at-write-time stance image blocks
  # take. Re-saving refreshes the snapshot. Accepts a previously stored map too
  # (API writers may round-trip the stored shape). Scoped to the writing tenant
  # so a media reference can't point across sites (epic #336).
  defp coerce_media(value, _def, tenant) do
    with {:ok, id} <- extract_id(value),
         {:ok, media} <- KilnCMS.CMS.get_media_item(id, authorize?: false, tenant: tenant) do
      {:ok, %{"id" => media.id, "url" => media.url, "alt" => media.alt}}
    else
      _ -> {:error, "must be an existing media item"}
    end
  end

  # A content reference: resolves the target id against the field's declared
  # `target_type` (compiled or dynamic) and stores a snapshot
  # (`%{"id", "type", "slug", "title"}`) — id/type are the stable keys
  # consumers fetch fresh content with; slug/title are display labels that may
  # go stale until the next save. Scoped to the writing tenant so a reference
  # can't point across sites (epic #336).
  defp coerce_reference(value, %{target_type: target}, tenant) do
    with {:ok, id} <- extract_id(value),
         ct when not is_nil(ct) <- KilnCMS.CMS.ContentTypes.get(target),
         {:ok, record} <-
           KilnCMS.CMS.ContentTypes.get_record(ct, id, authorize?: false, tenant: tenant) do
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
