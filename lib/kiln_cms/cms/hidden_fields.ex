defmodule KilnCMS.CMS.HiddenFields do
  @moduledoc """
  The read side of per-custom-field grants (#2281): which private custom fields
  an **editor** under a `field_read_grants` restriction may not see on a given
  document, and how to leave them out of a record, a working copy or a
  version's `changes`.

  `KilnCMS.CMS.Preparations.MaskPrivateFields` (reads),
  `KilnCMS.CMS.Changes.MaskHiddenFields` (mutation results) and
  `KilnCMS.CMS.Preparations.MaskVersionFields` (history) all decide through
  here, so the three cannot disagree. The grammar is `KilnCMS.CMS.FieldAccess`;
  a private field is always a top-level plain scalar
  (`KilnCMS.CMS.PrivateFields.types/0`), so only top-level keys are ever hidden
  and a group's rows carry nothing to drop.

  Callers decide WHEN to mask (skip `authorize?: false`, a system actor, an
  admin, a non-editor — who has a coarser rule of their own); this module
  answers WHAT, for an actor already known to be an editor of the org.
  """

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.FieldAccess
  alias KilnCMS.CMS.PrivateFields

  @doc """
  The private custom field names `actor` may not see on `document` (a content
  record, selected with `org_id` and, for an entry, `type_definition_id`).
  `[]` for an editor with no read restriction for the document's type.
  """
  @spec names(map(), struct(), term()) :: [String.t()]
  def names(actor, %{} = document, tenant \\ nil) do
    org_id = org_id(document, tenant)
    type = ContentTypes.type_name_for(document)

    case Scoping.field_read_grant(actor, org_id, type) do
      nil -> []
      read -> restricted(actor, org_id, type, read, PrivateFields.names_for(document, tenant))
    end
  end

  @doc """
  Like `names/3` for a document the caller can only name by its scope: `scope`
  is the key `PrivateFields.all/1` files its fields under (a type atom, or a
  dynamic type's definition id) and `type` its grant key (`ContentTypes`).
  """
  @spec names_for_scope(map(), Ash.UUID.t(), atom() | Ash.UUID.t(), String.t() | nil) ::
          [String.t()]
  def names_for_scope(actor, org_id, scope, type) do
    case Scoping.field_read_grant(actor, org_id, type) do
      nil -> []
      read -> restricted(actor, org_id, type, read, Map.get(PrivateFields.all(org_id), scope, []))
    end
  end

  @doc """
  Does `query` filter or sort on the `custom_fields` attribute itself — the
  whole stored map — in a way that could answer questions about a value the
  `actor` may not read (#2281)?

  `custom_fields` is a public attribute, so JSON:API and GraphQL derive
  `filter[custom_fields]` (an equality test against the whole map, hidden keys
  included) and `sort=custom_fields` from it. Both are oracles for a hidden
  key. The per-field `custom_filter` / `custom_sort` arguments are not: they
  resolve against the definitions the actor may see
  (`Preparations.CustomFieldQuery`).

  `true` only when the actor is restricted somewhere the query can reach: the
  query's type for a compiled resource, any dynamic type for the shared entry
  tier.
  """
  @spec probes_hidden?(map(), Ash.Query.t(), term()) :: boolean()
  def probes_hidden?(actor, %Ash.Query{} = query, tenant) do
    touches_custom_fields?(query) and restricted_somewhere?(actor, query.resource, tenant)
  end

  defp touches_custom_fields?(query) do
    filtered? =
      case query.filter do
        %Ash.Filter{expression: expression} -> probe?(expression)
        _none -> false
      end

    filtered? or Enum.any?(query.sort || [], fn {field, _dir} -> custom_fields?(field) end)
  end

  defp probe?(%Ash.Query.BooleanExpression{left: left, right: right}),
    do: probe?(left) or probe?(right)

  defp probe?(%Ash.Query.Not{expression: expression}), do: probe?(expression)

  defp probe?(%{__predicate__?: true} = predicate) do
    operands =
      [Map.get(predicate, :left), Map.get(predicate, :right)] ++
        List.wrap(Map.get(predicate, :arguments))

    Enum.any?(operands, &custom_fields?/1)
  end

  defp probe?(_other), do: false

  defp custom_fields?(:custom_fields), do: true
  defp custom_fields?(%Ash.Query.Ref{attribute: attribute}), do: custom_fields?(attribute)
  defp custom_fields?(%{name: :custom_fields}), do: true
  defp custom_fields?(_other), do: false

  defp restricted_somewhere?(actor, resource, tenant) do
    org_id = Accounts.org_id(tenant)

    if function_exported?(resource, :__kiln_dynamic_entry__, 0) do
      org_id
      |> ContentTypes.dynamic_all()
      |> Enum.any?(&(names_for_scope(actor, org_id, &1.definition.id, to_string(&1.type)) != []))
    else
      names_for_scope(
        actor,
        org_id,
        ContentTypes.type_atom(resource),
        ContentTypes.type_name(resource)
      ) != []
    end
  end

  @doc """
  What the console shows `actor` of a type's custom field `definitions`, given
  the type's `descriptor` (as `ContentTypes` lists it) on `org`:
  `{visible, read_only}` — `visible` is `definitions` without the private
  fields a read restriction hides, `read_only` the names of the top-level
  fields the editor's write grant does not cover (a group is read-only unless
  the whole group is granted). Admins and non-editors see everything as is.
  """
  @spec console_access(map() | nil, term(), map(), [struct()]) :: {[struct()], [String.t()]}
  def console_access(actor, org, descriptor, definitions) do
    org_id = Accounts.org_id(org)

    if is_map(actor) and Scoping.effective_tier(actor, org_id) == :editor do
      type = to_string(descriptor.type)
      read = Scoping.field_read_grant(actor, org_id, type)
      write = Scoping.field_grant(actor, org_id, type)
      hidden = FieldAccess.hidden_names(definitions, read, write)

      visible = Enum.reject(definitions, &(&1.name in hidden and top_level?(&1)))

      read_only =
        for definition <- visible,
            top_level?(definition),
            not FieldAccess.writable?(write, [definition.name]),
            do: definition.name

      {visible, read_only}
    else
      {definitions, []}
    end
  end

  @doc "The definitions `console_access/4` leaves visible."
  @spec visible_definitions(map() | nil, term(), map(), [struct()]) :: [struct()]
  def visible_definitions(actor, org, descriptor, definitions),
    do: actor |> console_access(org, descriptor, definitions) |> elem(0)

  defp top_level?(definition),
    do: is_nil(Map.get(definition, :link_of_id)) and is_nil(Map.get(definition, :group_of_id))

  defp restricted(actor, org_id, type, read, private_names) do
    write = Scoping.field_grant(actor, org_id, type)
    definitions = for name <- private_names, do: %{private: true, name: name}
    FieldAccess.hidden_names(definitions, read, write)
  end

  defp org_id(document, tenant) do
    case Map.get(document, :org_id) do
      id when is_binary(id) -> id
      _ -> Accounts.org_id(tenant)
    end
  end

  @doc """
  `document` without the `hidden` names: in `custom_fields`, and in the
  `"custom_fields"` map a held working copy keeps in `working_fields`. Anything
  not loaded (`%Ash.NotLoaded{}`) passes through.
  """
  @spec drop(struct(), [String.t()]) :: struct()
  def drop(document, []), do: document

  def drop(document, hidden) do
    document
    |> put_if_map(:custom_fields, &drop_keys(&1, hidden))
    |> put_if_map(:working_fields, &drop_working(&1, hidden))
  end

  defp drop_working(%{"custom_fields" => %{} = held} = fields, hidden),
    do: %{fields | "custom_fields" => drop_keys(held, hidden)}

  defp drop_working(fields, _hidden), do: fields

  @doc """
  A version's dumped `changes` map without the `hidden` names, in both places a
  snapshot keeps custom fields (`custom_fields`, and `working_fields`'
  `"custom_fields"`).
  """
  @spec drop_changes(term(), [String.t()]) :: term()
  def drop_changes(changes, []), do: changes

  def drop_changes(%{} = changes, hidden) when not is_struct(changes) do
    changes
    |> map_value("custom_fields", &drop_keys(&1, hidden))
    |> map_value("working_fields", &drop_working(&1, hidden))
  end

  def drop_changes(changes, _hidden), do: changes

  defp map_value(map, key, fun) do
    case Map.get(map, key) do
      %{} = value when not is_struct(value) -> Map.put(map, key, fun.(value))
      _other -> map
    end
  end

  # Keys are strings in a dumped snapshot and a stored map; a map built in
  # memory may spell them as atoms.
  defp drop_keys(map, hidden), do: Map.reject(map, fn {key, _} -> to_string(key) in hidden end)

  defp put_if_map(document, key, fun) do
    case Map.get(document, key) do
      %{} = value when not is_struct(value) -> Map.put(document, key, fun.(value))
      _other -> document
    end
  end
end
