defmodule KilnCMS.CMS.Changes.EnforceCustomFieldGrants do
  @moduledoc """
  Per-custom-field write scoping for editors (#2281; the grammar is
  `KilnCMS.CMS.FieldAccess`).

  Two rules, both for the acting editor of a document (admins, system and
  actor-less writes are exempt, exactly as in `Changes.EnforceFieldGrants`):

    * **Granted keys.** When the editor's effective `field_grants` for the type
      holds a `custom_fields.*` entry, they may only change the custom fields
      the grant names (`custom_fields.<name>`, a whole group, or one group
      sub-field in every row). A grant with only the bare `custom_fields` key,
      or none, is the old all-or-nothing rule and is judged by
      `EnforceFieldGrants`. On a **create** an editor holding any
      `custom_fields.*` entry is held to its keys too: a key outside it may
      only carry its default. Roles with only whole-attribute grants keep their
      creates ungoverned.
    * **Hidden keys.** A private field the editor's `field_read_grants` hides
      from them (`FieldAccess.hidden_names/3`) cannot be written by them
      either, on a create or an update.

  A restricted editor also may not run `:restore_version` for a type they hold
  a read restriction on: a restore rewrites `custom_fields` wholesale and would
  overwrite the values they cannot see. (A field-granted editor is already
  refused it by `EnforceFieldGrants`.)

  ## What counts as a change

  Only the keys the editor **supplied**, compared **after coercion** against the
  stored value, the way `KilnCMS.I18n.Validations.SharedFieldsReadOnly` judges a
  shared field. This is a resource-level change, so it runs after the action's
  own `Changes.ApplyCustomFields` and reads the coerced map that change wrote
  (`ApplyCustomFields.supplied_keys/1` names what was supplied); nothing is
  re-implemented. Re-sending the stored value in any spelling the form uses is
  not a change; a default filled into a key the payload never named is not a
  change; computed fields and stale (undefined) keys are not judged at all; a
  `:media` or `:reference` snapshot is the same value while its ids are. On a
  create, what a payload naming nothing would store (the defaults) comes from a
  throwaway run of `ApplyCustomFields`.

  A group is judged row by row: a group entry covers adding, removing and
  reordering rows; with only sub-field entries the row count must stay and each
  differing sub-field must be granted.

  Runs in the change phase (not a hook) so that the probe changeset
  `Changes.StageWorkingFields` builds for `:save_working_copy` meets it too.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.CMS.Changes.ApplyCustomFields
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.FieldAccess

  @impl true
  def change(changeset, _opts, %{actor: %{} = actor} = context) do
    case restriction(changeset, actor) do
      nil -> changeset
      restriction -> enforce(changeset, restriction, context)
    end
  end

  def change(changeset, _opts, _context), do: changeset

  @typedoc "What the acting editor is held to for this write."
  @type restriction :: %{
          write: FieldAccess.grant(),
          read: FieldAccess.grant(),
          per_key?: boolean(),
          hidden: [String.t()],
          definitions: [struct()]
        }

  @doc """
  The custom-field restriction `actor` is under for `changeset`'s document, or
  `nil` when there is none (an effective admin or non-editor, or no `custom_fields.*`
  write entry and no read restriction for the type).
  """
  @spec restriction(Ash.Changeset.t(), map()) :: restriction() | nil
  def restriction(changeset, actor) do
    with :editor <- Scoping.effective_tier(actor, changeset),
         type when is_binary(type) <- ContentTypes.type_name_for(changeset) do
      write = Scoping.field_grant(actor, changeset, type)
      read = Scoping.field_read_grant(actor, changeset, type)
      per_key? = FieldAccess.per_key?(write)

      if per_key? or read != nil do
        definitions =
          ApplyCustomFields.definitions(
            changeset.resource,
            Ash.Changeset.get_attribute(changeset, :type_definition_id),
            changeset.to_tenant
          )

        %{
          write: write,
          read: read,
          per_key?: per_key?,
          hidden: FieldAccess.hidden_names(definitions, read, write),
          definitions: definitions
        }
      end
    else
      _not_restricted -> nil
    end
  end

  # A restore force-changes the whole map; nothing key-wise can scope it.
  defp enforce(%{action: %{name: :restore_version}} = changeset, %{read: read}, _context)
       when is_list(read) do
    Ash.Changeset.add_error(changeset,
      field: :version_id,
      message: "restoring a version requires full field access for this content type"
    )
  end

  defp enforce(changeset, restriction, context) do
    if judged?(changeset) and (restriction.per_key? or restriction.hidden != []) do
      changeset
      |> changed_paths(restriction, context)
      |> Enum.reject(&allowed?(&1, restriction))
      |> Enum.reduce(changeset, &add_violation(&2, &1))
    else
      changeset
    end
  end

  # Only a write that carries `custom_fields` has keys to judge (an update that
  # leaves it alone only refreshes computed fields).
  defp judged?(changeset) do
    changeset.action_type in [:create, :update] and
      Ash.Changeset.changing_attribute?(changeset, :custom_fields)
  end

  # ── what changed ──────────────────────────────────────────────────────────

  # The paths (`["name"]`, `["group", "sub"]`) the editor's payload moves.
  defp changed_paths(changeset, restriction, context) do
    # A default the payload left the field blank for (#2286) is the system's
    # value, not the editor's edit.
    supplied =
      (ApplyCustomFields.supplied_keys(changeset) || []) --
        ApplyCustomFields.defaulted_keys(changeset)

    new = Ash.Changeset.get_attribute(changeset, :custom_fields) || %{}
    old = current(changeset, context)

    for definition <- restriction.definitions,
        editable?(definition),
        definition.name in supplied,
        path <- paths(definition, Map.get(new, definition.name), Map.get(old, definition.name)),
        do: path
  end

  # A throwaway run of the real coercion (its errors are the real change's to
  # report), for what a create stores when the payload names nothing.
  defp coerce(changeset, context), do: ApplyCustomFields.change(changeset, [], context)

  # The value each key had before this write: the stored map on an update; on a
  # create, what a payload naming nothing would store (the defaults).
  defp current(%{action_type: :update, data: data}, _context),
    do: stringify(data.custom_fields || %{})

  defp current(changeset, context) do
    blank = Ash.Changeset.force_change_attribute(changeset, :custom_fields, %{})
    blank |> coerce(context) |> Ash.Changeset.get_attribute(:custom_fields) |> Kernel.||(%{})
  end

  # Top-level, editor-filled definitions: not a link or group sub-field (they
  # ride on their parent), not computed (the engine's, never supplied).
  defp editable?(definition) do
    definition.field_type != :computed and is_nil(Map.get(definition, :link_of_id)) and
      is_nil(Map.get(definition, :group_of_id))
  end

  defp paths(%{field_type: :group} = definition, new, old) do
    {new_rows, old_rows} = {rows(definition, new), rows(definition, old)}

    cond do
      new_rows == old_rows -> []
      length(new_rows) != length(old_rows) -> [[definition.name]]
      true -> sub_paths(definition.name, new_rows, old_rows)
    end
  end

  defp paths(%{name: name, field_type: type}, new, old),
    do: if(comparable(type, new) == comparable(type, old), do: [], else: [[name]])

  # A row's own spelling of "no value" differs from key to key; compare the
  # rows as stored. A single (non-repeating) group is one row, missing = empty.
  defp rows(%{multiple: true}, value), do: List.wrap(value)
  defp rows(_definition, nil), do: [%{}]
  defp rows(_definition, value), do: [value]

  defp sub_paths(group, new_rows, old_rows) do
    new_rows
    |> Enum.zip(old_rows)
    |> Enum.flat_map(fn {new, old} ->
      new = new || %{}
      old = old || %{}

      for sub <- Enum.uniq(Map.keys(new) ++ Map.keys(old)),
          Map.get(new, sub) != Map.get(old, sub),
          do: [group, sub]
    end)
    |> Enum.uniq()
  end

  # A media or reference snapshot is the same value while its ids are.
  defp comparable(type, value) when type in [:media, :reference],
    do: ApplyCustomFields.snapshot_ids(value)

  defp comparable(_type, value), do: value

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  # ── what is allowed ───────────────────────────────────────────────────────

  defp allowed?([name | _] = path, restriction) do
    name not in restriction.hidden and
      (not restriction.per_key? or FieldAccess.writable?(restriction.write, path))
  end

  defp add_violation(changeset, path) do
    Ash.Changeset.add_error(changeset,
      field: :custom_fields,
      message:
        "#{FieldAccess.key(path)} cannot be changed: outside your field grant for this content type"
    )
  end
end
