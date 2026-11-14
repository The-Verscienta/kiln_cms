defmodule KilnCMS.CMS.Validations.ReferenceSelection do
  @moduledoc """
  Keeps a reference field's `selection` (#2285, `KilnCMS.CMS.ReferenceSelection`)
  writable and enforceable:

    * the map has a valid shape (no unknown keys, `states` among the content
      states, `owner` only `"self"`, `sort` `recent` or `title`);
    * `create` is refused for now: letting an editor create a record from the
      picker is a later release;
    * a `by_type` key is one of the field's own target types, so narrowing the
      targets while a condition names a type that leaves them is refused;
    * a `fields` name is a custom field of that type that is not private and
      has a plain equality (`ReferenceSelection.equality_field?/1`), and its
      value is one the field accepts;
    * a `tags_any` / `category` id names a tag or category of this site.

  The other direction is guarded too: making a field a selection names
  **private**, or retyping it to a type with no equality, is refused while any
  reference definition's `selection` names it, because a filter on a value the
  picking editor cannot read would let them infer it from which candidates
  appear. Destroying or renaming a named field is *not* guarded: the evaluator
  ignores a condition whose field is gone, so the filter stays inert rather than
  turning every save into an error.

  Tags and categories work on dynamic (`Entry`) types as on compiled ones: the
  entry tier has the same `tags` and `category` relationships.
  """
  use Ash.Resource.Validation
  use Gettext, backend: KilnCMSWeb.Gettext

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.CMS.FieldValue
  alias KilnCMS.CMS.ReadGrants
  alias KilnCMS.CMS.ReferenceSelection

  @impl true
  def validate(changeset, _opts, _context) do
    with :ok <- check_own(changeset) do
      check_named(changeset)
    end
  end

  # --- this field's selection --------------------------------------------------

  defp check_own(changeset) do
    case ReferenceSelection.normalize(Ash.Changeset.get_attribute(changeset, :selection)) do
      nil ->
        :ok

      selection ->
        with :ok <- check_owner(changeset),
             :ok <- check_shape(selection),
             :ok <- check_create(selection) do
          check_by_type(selection, changeset, content_changed?(changeset))
        end
    end
  end

  defp check_owner(changeset) do
    top_level? =
      is_nil(Ash.Changeset.get_attribute(changeset, :link_of_id)) and
        is_nil(Ash.Changeset.get_attribute(changeset, :group_of_id))

    if Ash.Changeset.get_attribute(changeset, :field_type) == :reference and top_level? do
      :ok
    else
      error(:selection, gettext("is only for a reference field"))
    end
  end

  defp check_shape(selection) do
    case ReferenceSelection.check_shape(selection) do
      :ok ->
        :ok

      {:error, reason} ->
        error(:selection, gettext("is not valid: it %{reason}", reason: reason))
    end
  end

  # The creating picker is a later release; until then a stored `create`
  # would promise a row the picker does not have.
  defp check_create(%{"create" => _create}),
    do:
      error(
        :selection,
        gettext("can't let editors create records yet: that is coming in a later release")
      )

  defp check_create(_selection), do: :ok

  # What the selection names (tags, categories, fields and their values) is
  # judged when the selection is written, never on an unrelated edit: a tag
  # deleted since is drift, which the evaluator drops (module doc). Which types
  # it names is judged whenever the targets move too.
  defp content_changed?(%{action_type: :create}), do: true
  defp content_changed?(changeset), do: Ash.Changeset.changing_attribute?(changeset, :selection)

  defp check_by_type(%{"by_type" => %{} = by_type}, changeset, content?) do
    targets = FieldDefinition.reference_targets(Map.new(target_attrs(changeset)))
    org_id = KilnCMS.Accounts.org_id(changeset.to_tenant)

    Enum.find_value(by_type, :ok, fn {type, entry} ->
      cond do
        type not in targets ->
          error(
            :selection,
            gettext("names %{type}, which is not one of this field's target types", type: type)
          )

        content? ->
          entry_problem(entry, type, org_id)

        true ->
          nil
      end
    end)
  end

  defp check_by_type(_selection, _changeset, _content?), do: :ok

  defp entry_problem(entry, type, org_id) do
    case ContentTypes.get(type, org_id) do
      nil -> nil
      descriptor -> problem(entry, descriptor, type, org_id)
    end
  end

  defp target_attrs(changeset) do
    for attr <- [:target_type, :target_types],
        do: {attr, Ash.Changeset.get_attribute(changeset, attr)}
  end

  # nil when the entry is fine, else the error tuple.
  defp problem(entry, descriptor, type, org_id) do
    with nil <- ids_problem(:tag, Map.get(entry, "tags_any"), type, org_id),
         nil <- ids_problem(:category, List.wrap(Map.get(entry, "category")), type, org_id) do
      fields_problem(Map.get(entry, "fields"), descriptor, type, org_id)
    end
  end

  defp ids_problem(_kind, ids, _type, _org_id) when ids in [nil, []], do: nil

  defp ids_problem(kind, ids, type, org_id) do
    case ids -- ReferenceSelection.existing_ids(kind, ids, org_id) do
      [] -> nil
      [_ | _] -> error(:selection, missing_taxonomy(kind, type))
    end
  end

  defp missing_taxonomy(:tag, type),
    do: gettext("names a tag for %{type} that does not exist on this site", type: type)

  defp missing_taxonomy(:category, type),
    do: gettext("names a category for %{type} that does not exist on this site", type: type)

  defp fields_problem(%{} = fields, descriptor, type, org_id) do
    by_name =
      descriptor |> ReferenceSelection.field_definitions(org_id) |> Map.new(&{&1.name, &1})

    Enum.find_value(fields, fn {name, value} ->
      case Map.fetch(by_name, name) do
        :error ->
          error(
            :selection,
            gettext("names %{field}, which is not a field of %{type}", field: name, type: type)
          )

        {:ok, definition} ->
          field_problem(definition, value, type)
      end
    end)
  end

  defp fields_problem(_none, _descriptor, _type, _org_id), do: nil

  defp field_problem(%{private: true} = definition, _value, type),
    do:
      error(
        :selection,
        gettext("can't filter %{type} by %{field}, a private field",
          type: type,
          field: definition.name
        )
      )

  defp field_problem(definition, value, type) do
    if ReferenceSelection.equality_field?(definition) do
      value_problem(definition, value)
    else
      error(
        :selection,
        gettext("can't filter %{type} by %{field}: a %{kind} field has no plain value to match",
          type: type,
          field: definition.name,
          kind: definition.field_type
        )
      )
    end
  end

  defp value_problem(definition, value) do
    single = %{definition | multiple: false}

    values =
      case value do
        %{"in" => list} -> list
        %{"not_eq" => one} -> [one]
        one -> [one]
      end

    Enum.find_value(values, fn candidate ->
      case FieldValue.coerce(candidate, single) do
        {:ok, _value} ->
          nil

        {:error, message} ->
          error(
            :selection,
            gettext("has a value for %{field} that it does not accept: it %{reason}",
              field: definition.name,
              reason: message
            )
          )
      end
    end)
  end

  # --- fields a selection names ------------------------------------------------

  # Turning a named field private, or retyping it to something without a
  # plain equality, would leave a condition the picker cannot honor.
  defp check_named(%{action_type: :update} = changeset) do
    data = changeset.data
    org_id = KilnCMS.Accounts.org_id(changeset.to_tenant)

    with true <- turning_unfit?(changeset),
         type when is_binary(type) <- ReadGrants.type_name(data, org_id),
         [_ | _] = named <- named_by(type, data.name, org_id) do
      labels = Enum.map_join(named, ", ", & &1.label)
      field = if private_flip?(changeset), do: :private, else: :field_type

      error(
        field,
        gettext("is used by the selection of %{fields}; remove it from there first",
          fields: labels
        )
      )
    else
      _fine -> :ok
    end
  end

  defp check_named(_changeset), do: :ok

  defp turning_unfit?(changeset) do
    private_flip?(changeset) or retyped_unfit?(changeset)
  end

  defp private_flip?(changeset),
    do:
      changeset.data.private == false and
        Ash.Changeset.get_attribute(changeset, :private) == true

  defp retyped_unfit?(changeset) do
    Ash.Changeset.changing_attribute?(changeset, :field_type) and
      Ash.Changeset.get_attribute(changeset, :field_type) not in ReferenceSelection.equality_types()
  end

  defp named_by(type, name, org_id) do
    for {definition, names} <- ReferenceSelection.named_fields(type, org_id),
        name in names,
        do: definition
  end

  defp error(field, message, value \\ nil),
    do: {:error, InvalidAttribute.exception(field: field, message: message, value: value)}
end
