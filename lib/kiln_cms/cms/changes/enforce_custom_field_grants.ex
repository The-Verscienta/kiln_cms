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

  A flexible field (#2282) is judged item by item, matched by `_id` and not by
  position: `custom_fields.<field>.<item type>` covers adding, removing and
  editing (sub-fields, settings, anything nested) the items of that type. A
  changed item needs the grant of its type, an added or removed item needs the
  grant of its type, and an item whose `_type` changes needs both. Putting the
  surviving items in a different order needs the whole-field entry, because it
  moves items of every type. A list whose items do not all carry one distinct
  `_id` (it cannot be matched) is judged as a whole.

  Runs in the change phase (not a hook) so that the probe changeset
  `Changes.StageWorkingFields` builds for `:save_working_copy` meets it too.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.CMS.Changes.ApplyCustomFields
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.FieldAccess
  alias KilnCMS.CMS.FieldDefinition

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
    definition.field_type != :computed and FieldDefinition.top_level?(definition)
  end

  defp paths(%{field_type: :group} = definition, new, old) do
    {new_rows, old_rows} = {rows(definition, new), rows(definition, old)}

    cond do
      new_rows == old_rows -> []
      length(new_rows) != length(old_rows) -> [[definition.name]]
      true -> sub_paths(definition.name, new_rows, old_rows)
    end
  end

  defp paths(%{field_type: :flexible, name: name} = definition, new, old) do
    {new_items, old_items} = {List.wrap(new), List.wrap(old)}

    cond do
      new_items == old_items -> []
      not identified?(new_items) or not identified?(old_items) -> [[name]]
      true -> item_paths(definition, new_items, old_items)
    end
  end

  defp paths(%{name: name} = definition, new, old),
    do: if(comparable(definition, new) == comparable(definition, old), do: [], else: [[name]])

  # Every item a map with a binary `_type` and a distinct binary `_id`.
  defp identified?(items) do
    ids = for %{"_id" => id} when is_binary(id) <- items, do: id

    length(ids) == length(items) and length(Enum.uniq(ids)) == length(ids) and
      Enum.all?(items, &(is_map(&1) and is_binary(Map.get(&1, "_type"))))
  end

  defp item_paths(%{name: name} = definition, new_items, old_items) do
    types = Map.new(FieldDefinition.item_types(definition), &{&1.name, &1})
    {new_by, old_by} = {by_id(new_items), by_id(old_items)}

    added = for {id, item} <- new_by, not is_map_key(old_by, id), do: [name, item["_type"]]
    removed = for {id, item} <- old_by, not is_map_key(new_by, id), do: [name, item["_type"]]

    changed =
      for {id, new_item} <- new_by,
          old_item = Map.get(old_by, id),
          item_comparable(new_item, types) != item_comparable(old_item, types),
          type <- Enum.uniq([new_item["_type"], old_item["_type"]]),
          do: [name, type]

    common = MapSet.intersection(MapSet.new(Map.keys(new_by)), MapSet.new(Map.keys(old_by)))
    order = fn items -> for %{"_id" => id} <- items, id in common, do: id end
    reordered = if order.(new_items) == order.(old_items), do: [], else: [[name]]

    Enum.uniq(added ++ removed ++ changed ++ reordered)
  end

  defp by_id(items), do: Map.new(items, &{&1["_id"], &1})

  # An item with the snapshots of its media and references cut to their ids,
  # at any depth, so a refreshed title in a type the editor cannot write is
  # not their change.
  defp item_comparable(item, types) do
    case Map.fetch(types, item["_type"]) do
      {:ok, type} ->
        subs = Map.new(FieldDefinition.group_fields(type), &{&1.name, &1})

        # Only the keys the type still declares count: a stale key an admin
        # removed from the type is not the editor's change when coercion drops it.
        item
        |> Map.take(["_id", "_type", "_settings" | Map.keys(subs)])
        |> Map.new(fn
          {"_settings", %{} = settings} -> {"_settings", comparable_map(settings, subs)}
          {key, value} -> {key, comparable_value(Map.get(subs, key), value)}
        end)

      :error ->
        item
    end
  end

  defp comparable_map(map, subs),
    do: Map.new(map, fn {key, value} -> {key, comparable_value(Map.get(subs, key), value)} end)

  defp comparable_value(nil, value), do: value
  defp comparable_value(definition, value), do: comparable(definition, value)

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
  defp comparable(%{field_type: type}, value) when type in [:media, :reference],
    do: ApplyCustomFields.snapshot_ids(value)

  # A flexible field nested in an item: its own items, snapshots cut to ids.
  defp comparable(%{field_type: :flexible} = definition, value) when is_list(value) do
    types = Map.new(FieldDefinition.item_types(definition), &{&1.name, &1})
    for item <- value, do: if(is_map(item), do: item_comparable(item, types), else: item)
  end

  defp comparable(_definition, value), do: value

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
