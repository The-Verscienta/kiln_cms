defmodule KilnCMS.CMS.ReferenceSelection do
  @moduledoc """
  Which records a `:reference` field may add (#2285): the closed vocabulary of
  `FieldDefinition.selection`, and the one evaluator that turns it into a read
  filter. `docs/plans/reference-selection-plan.md` is the design.

      %{
        "states" => ["published"],
        "owner" => "self",
        "sort" => "title",
        "by_type" => %{
          "ingredient" => %{
            "tags_any" => ["<tag id>"],
            "category" => "<category id>",
            "fields" => %{"diet" => "vegan", "region" => %{"in" => ["eu", "uk"]}}
          }
        }
      }

  Conditions AND together. A condition names what the server knows how to
  evaluate; raw filters are never accepted. The map is **not an access
  control**: it is one more `AND` on a read the actor's own policy already
  gates, so it only ever narrows what the actor can read.

  ## One evaluator

  `query_for/5` is the only code that turns a selection into read options. The
  picker (a later change) and the save-time check in
  `KilnCMS.CMS.Changes.ApplyCustomFields` both call it and read through the
  same action, so one cannot offer what the other refuses.

  The result is read options for `KilnCMS.CMS.ContentTypes.list!/2` (see
  `read_opts/2`):

    * `state`, `author_id`, `category_id` and the tag condition are native
      `query: [filter:]` expressions — `category` is not a `custom_filter` key,
      and a custom field named `tags` would shadow the built-in `tags` there;
    * `fields` go through the `custom_filter` read argument, whose grammar and
      privacy rules are `KilnCMS.CMS.Preparations.CustomFieldQuery`'s.

  ## Drift is inert, never an error

  A condition that names something that no longer exists is **dropped**, not
  turned into "match nothing": a type that left the registry, a field that was
  deleted, renamed, made private or retyped to a type without equality, and a
  tag or category that was deleted. The other conditions and the actor's read
  policy still bound the result, and a stale filter cannot lock editors out.
  Destroying or renaming a field a selection names is therefore not guarded
  (only making it private or retyping it is, `Validations.ReferenceSelection`).

  ## Who it does not bind

  A `%KilnCMS.SystemActor{}` or a read with `authorize?: false` gets
  `:unfiltered`: bookkeeping writes skip the filter the way they skip the
  snapshot masking, and still resolve each target. A `nil` actor with
  authorization on is **not** a skip: `owner: "self"` matches nothing for it,
  and the read policy decides the rest.
  """

  import Ash.Expr

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.FieldDefinition

  @top_keys ~w(states owner sort by_type create)
  @type_keys ~w(tags_any category fields)
  @states ~w(draft in_review published archived)
  @state_atoms %{
    "draft" => :draft,
    "in_review" => :in_review,
    "published" => :published,
    "archived" => :archived
  }
  @sorts ~w(recent title)

  # The custom field types a `fields` condition may name: the scalars whose
  # `custom_filter` equality means what an admin expects. Not media, reference,
  # group, geolocation, link (no scalar to compare), and not rich text.
  @equality_types ~w(string integer float boolean date datetime url select email telephone color slug time)a

  @max_ids 50
  @max_fields 10
  @max_in 50

  @type t :: map()
  @type plan :: [filter: [term()], arguments: map()]

  @doc "The content states `states` may name."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "The sort orders `sort` may name."
  @spec sorts() :: [String.t()]
  def sorts, do: @sorts

  @doc "The condition keys a `by_type` entry may carry."
  @spec type_keys() :: [String.t()]
  def type_keys, do: @type_keys

  @doc "The custom field types a `fields` condition may name."
  @spec equality_types() :: [atom()]
  def equality_types, do: @equality_types

  @doc "Whether `definition` is a field a `fields` condition may name."
  @spec equality_field?(map()) :: boolean()
  def equality_field?(definition) do
    Map.get(definition, :field_type) in @equality_types and
      Map.get(definition, :private) != true and is_nil(Map.get(definition, :link_of_id)) and
      is_nil(Map.get(definition, :group_of_id))
  end

  # --- shape ---------------------------------------------------------------

  @doc """
  A selection with string keys and string values throughout, or `nil` for no
  selection (`nil`, or an empty map). Anything else comes back keyed as given
  so `check_shape/1` can name what is wrong with it.
  """
  @spec normalize(term()) :: t() | nil
  def normalize(nil), do: nil
  def normalize(%{} = selection) when map_size(selection) == 0, do: nil
  def normalize(selection), do: stringify(selection)

  defp stringify(%{} = map) when not is_struct(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)

  defp stringify(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: to_string(value)

  defp stringify(value), do: value

  @doc """
  `:ok`, or `{:error, reason}` with a short English reason naming the first
  thing wrong with the shape of `selection`. The reason is for the admin; the
  caller wraps it. Says nothing about whether names, types, tags or categories
  exist (`Validations.ReferenceSelection` checks those) nor about `create`.
  """
  @spec check_shape(term()) :: :ok | {:error, String.t()}
  def check_shape(selection) do
    case normalize(selection) do
      nil -> {:error, "is empty"}
      %{} = map -> shape(map)
    end
  end

  defp shape(map) do
    with :ok <- known_keys(map, @top_keys, "the selection"),
         :ok <- states_shape(Map.get(map, "states")),
         :ok <- owner_shape(Map.get(map, "owner")),
         :ok <- sort_shape(Map.get(map, "sort")) do
      by_type_shape(Map.get(map, "by_type"))
    end
  end

  defp known_keys(map, allowed, what) do
    case Map.keys(map) -- allowed do
      [] -> :ok
      [key | _] -> {:error, "has an unknown key #{inspect(key)} in #{what}"}
    end
  end

  defp states_shape(nil), do: :ok

  defp states_shape(states) when is_list(states) do
    cond do
      states != Enum.uniq(states) -> {:error, "lists a state twice"}
      Enum.all?(states, &(&1 in @states)) -> :ok
      true -> {:error, "states must be among #{Enum.join(@states, ", ")}"}
    end
  end

  defp states_shape(_other), do: {:error, "states must be a list"}

  defp owner_shape(nil), do: :ok
  defp owner_shape("self"), do: :ok
  defp owner_shape(_other), do: {:error, "owner can only be \"self\""}

  defp sort_shape(nil), do: :ok
  defp sort_shape(sort) when sort in @sorts, do: :ok
  defp sort_shape(_other), do: {:error, "sort must be one of #{Enum.join(@sorts, ", ")}"}

  defp by_type_shape(nil), do: :ok

  defp by_type_shape(by_type) when is_map(by_type) do
    Enum.find_value(by_type, :ok, fn {type, entry} ->
      case type_entry_shape(type, entry) do
        :ok -> nil
        error -> error
      end
    end)
  end

  defp by_type_shape(_other), do: {:error, "by_type must be an object keyed by type name"}

  defp type_entry_shape(type, %{} = entry) do
    with :ok <- known_keys(entry, @type_keys, "the conditions for #{type}"),
         :ok <- id_list_shape(Map.get(entry, "tags_any"), "tags_any"),
         :ok <- category_shape(Map.get(entry, "category")) do
      fields_shape(Map.get(entry, "fields"))
    end
  end

  defp type_entry_shape(type, _other),
    do: {:error, "the conditions for #{type} must be an object"}

  defp id_list_shape(nil, _key), do: :ok

  defp id_list_shape(ids, key) when is_list(ids) do
    cond do
      ids == [] -> {:error, "#{key} is empty"}
      length(ids) > @max_ids -> {:error, "#{key} lists more than #{@max_ids} ids"}
      not Enum.all?(ids, &uuid?/1) -> {:error, "#{key} must be a list of ids"}
      true -> :ok
    end
  end

  defp id_list_shape(_other, key), do: {:error, "#{key} must be a list of ids"}

  defp category_shape(nil), do: :ok
  defp category_shape(id) when is_binary(id), do: if(uuid?(id), do: :ok, else: bad_category())
  defp category_shape(_other), do: bad_category()

  defp bad_category, do: {:error, "category must be one category id"}

  defp fields_shape(nil), do: :ok

  defp fields_shape(fields) when is_map(fields) and map_size(fields) > @max_fields,
    do: {:error, "names more than #{@max_fields} fields"}

  defp fields_shape(fields) when is_map(fields) and map_size(fields) > 0 do
    Enum.find_value(fields, :ok, fn {name, value} ->
      case field_value_shape(name, value) do
        :ok -> nil
        error -> error
      end
    end)
  end

  defp fields_shape(_other), do: {:error, "fields must be an object of field name and value"}

  defp field_value_shape(name, %{"in" => values} = condition) when map_size(condition) == 1 do
    cond do
      not is_list(values) or values == [] -> {:error, "#{name}: in needs a list of values"}
      length(values) > @max_in -> {:error, "#{name}: in lists more than #{@max_in} values"}
      Enum.all?(values, &scalar?/1) -> :ok
      true -> {:error, "#{name}: in takes plain values"}
    end
  end

  defp field_value_shape(name, %{"not_eq" => value} = condition) when map_size(condition) == 1,
    do: if(scalar?(value), do: :ok, else: {:error, "#{name}: not_eq takes one plain value"})

  defp field_value_shape(name, %{}),
    do: {:error, "#{name} takes a value, {\"in\": [...]} or {\"not_eq\": value}"}

  defp field_value_shape(name, value),
    do: if(scalar?(value), do: :ok, else: {:error, "#{name} takes a plain value"})

  defp scalar?(value), do: is_binary(value) or is_number(value) or is_boolean(value)

  defp uuid?(value), do: is_binary(value) and match?({:ok, _}, Ecto.UUID.cast(value))

  # --- evaluation ----------------------------------------------------------

  @doc """
  The read conditions `selection` puts on candidates of target `type`, for the
  `actor` writing in `tenant`.

  `{:ok, :unfiltered}` when there is nothing to add — no selection, no live
  condition, or a caller the selection does not bind (see the moduledoc).
  Otherwise `{:ok, [filter: [...], arguments: %{...}]}`: `filter` is a list of
  terms for `query: [filter: term]` entries, `arguments` the read action's own
  arguments. Merge them into read options with `read_opts/2`.

  Options: `:read_opts` — the options the read will run with, consulted for
  `authorize?: false`.
  """
  @spec query_for(term(), String.t() | atom(), term(), term(), keyword()) ::
          {:ok, :unfiltered | plan()}
  def query_for(selection, type, actor, tenant, opts \\ []) do
    selection = normalize(selection)

    cond do
      is_nil(selection) ->
        {:ok, :unfiltered}

      skip?(actor, Keyword.get(opts, :read_opts, [])) ->
        {:ok, :unfiltered}

      true ->
        org_id = KilnCMS.Accounts.org_id(tenant)
        type = to_string(type)

        top = top_filters(selection, actor)
        {typed, arguments} = type_conditions(Map.get(selection, "by_type"), type, org_id)

        case top ++ typed do
          [] when arguments == %{} -> {:ok, :unfiltered}
          filters -> {:ok, [filter: filters, arguments: arguments]}
        end
    end
  end

  # A system actor (bookkeeping writes) and a read that skips authorization
  # are not bound by the picker's narrowing. A nil actor with authorization on
  # is a real caller, not a skip.
  defp skip?(%KilnCMS.SystemActor{}, _read_opts), do: true
  defp skip?(_actor, read_opts), do: Keyword.get(read_opts, :authorize?) == false

  defp top_filters(selection, actor) do
    states(Map.get(selection, "states")) ++ owner(Map.get(selection, "owner"), actor)
  end

  defp states(states) when is_list(states) and states != [] do
    atoms = for state <- states, atom = @state_atoms[state], do: atom
    if atoms == [], do: [], else: [[state: [in: atoms]]]
  end

  defp states(_none), do: []

  defp owner("self", %User{id: id}) when is_binary(id), do: [[author_id: id]]
  # An actor that is not a user has no records of its own: nothing matches.
  defp owner("self", _actor), do: [expr(false)]
  defp owner(_none, _actor), do: []

  defp type_conditions(%{} = by_type, type, org_id) do
    with %{} = entry <- Map.get(by_type, type),
         %{} = descriptor <- ContentTypes.get(type, org_id) do
      entry_conditions(entry, descriptor, org_id)
    else
      _inert -> {[], %{}}
    end
  end

  defp type_conditions(_none, _type, _org_id), do: {[], %{}}

  defp entry_conditions(entry, descriptor, org_id) do
    filters =
      tags_filter(live_ids(Map.get(entry, "tags_any"), :tag, org_id)) ++
        category_filter(live_ids(List.wrap(Map.get(entry, "category")), :category, org_id))

    {filters, field_arguments(Map.get(entry, "fields"), descriptor, org_id)}
  end

  defp tags_filter([]), do: []
  defp tags_filter(ids), do: [expr(exists(tags, id in ^ids))]

  defp category_filter([id]), do: [[category_id: id]]
  defp category_filter(_none), do: []

  defp field_arguments(%{} = fields, descriptor, org_id) when map_size(fields) > 0 do
    live = fields |> Map.keys() |> live_field_names(descriptor, org_id)

    case Map.take(fields, live) do
      map when map_size(map) == 0 -> %{}
      map -> %{custom_filter: map}
    end
  end

  defp field_arguments(_none, _descriptor, _org_id), do: %{}

  @doc """
  Merges a plan from `query_for/5` into the options of `ContentTypes.list!/2`:
  every filter term becomes a `query: [filter:]` entry (they AND with the
  caller's) and the arguments are merged into `arguments:`.
  """
  @spec read_opts(keyword(), :unfiltered | plan()) :: keyword()
  def read_opts(opts, :unfiltered), do: opts

  def read_opts(opts, filter: filters, arguments: arguments) do
    query = Keyword.get(opts, :query, [])

    opts
    |> Keyword.put(:query, Enum.map(filters, &{:filter, &1}) ++ query)
    |> Keyword.update(:arguments, arguments, &Map.merge(&1, arguments))
  end

  # --- what still exists -----------------------------------------------------

  # The ids of `kind` (`:tag` or `:category`) that still exist in the org; the
  # rest are dropped. Both are world-readable taxonomy, read under the tenant.
  defp live_ids(ids, kind, org_id) when is_list(ids) and ids != [] do
    ids = Enum.filter(ids, &uuid?/1)
    existing = existing_ids(kind, ids, org_id)
    Enum.filter(ids, &(&1 in existing))
  end

  defp live_ids(_none, _kind, _org_id), do: []

  @doc """
  The ids among `ids` that name a `kind` (`:tag` or `:category`) in the org.
  Taxonomy is world-readable, so this reads under the tenant alone.
  """
  @spec existing_ids(:tag | :category, [String.t()], term()) :: [String.t()]
  def existing_ids(kind, ids, tenant),
    do: do_existing_ids(kind, ids, KilnCMS.Accounts.org_id(tenant))

  defp do_existing_ids(_kind, [], _org_id), do: []

  defp do_existing_ids(:tag, ids, org_id) do
    [query: [filter: [id: [in: ids]], select: [:id]], tenant: org_id]
    |> CMS.list_tags!()
    |> Enum.map(& &1.id)
  end

  defp do_existing_ids(:category, ids, org_id) do
    [query: [filter: [id: [in: ids]], select: [:id]], tenant: org_id]
    |> CMS.list_categories!()
    |> Enum.map(& &1.id)
  end

  defp live_field_names(names, descriptor, org_id) do
    live = descriptor |> field_definitions(org_id) |> Enum.filter(&equality_field?/1)
    live = MapSet.new(live, & &1.name)
    Enum.filter(names, &MapSet.member?(live, &1))
  end

  @doc """
  The field definitions of the content type `descriptor` (from
  `KilnCMS.CMS.ContentTypes.get/2`), as the cms registry reader and failing
  closed: a refused read raises rather than answering "no fields", which would
  drop every field condition.
  """
  @spec field_definitions(map(), term()) :: [FieldDefinition.t()]
  def field_definitions(descriptor, tenant) do
    opts = [
      actor: KilnCMS.CMS.Housekeeping.system(:cms_registry),
      authorize_with: :error,
      tenant: KilnCMS.Accounts.org_id(tenant)
    ]

    case descriptor do
      %{source: :dynamic, definition: definition} ->
        CMS.field_definitions_for_definition!(definition.id, opts)

      %{type: type} ->
        CMS.field_definitions_for!(type, opts)
    end
  end

  @doc """
  The live part of a field's selection, as `SchemaExport` reports it: the
  normalized map without the entries `query_for/5` would drop — a `by_type`
  key outside the field's target types or the registry, a field that is gone
  or no longer a plain equality field, a deleted tag or category. `nil` when
  nothing is left. Tag and category stay ids.
  """
  @spec live(term(), [String.t()], term()) :: t() | nil
  def live(selection, targets, tenant) do
    org_id = KilnCMS.Accounts.org_id(tenant)

    case normalize(selection) do
      %{} = map ->
        map
        |> Map.take(~w(states owner sort by_type))
        |> live_by_type(targets, org_id)
        |> normalize()

      _none ->
        nil
    end
  end

  defp live_by_type(%{"by_type" => %{} = by_type} = map, targets, org_id) do
    live =
      for {type, entry} <- by_type,
          type in targets,
          %{} = descriptor <- [ContentTypes.get(type, org_id)],
          %{} = kept <- [live_entry(entry, descriptor, org_id)],
          into: %{},
          do: {type, kept}

    if live == %{}, do: Map.delete(map, "by_type"), else: Map.put(map, "by_type", live)
  end

  defp live_by_type(map, _targets, _org_id), do: Map.delete(map, "by_type")

  defp live_entry(%{} = entry, descriptor, org_id) do
    tags = live_ids(Map.get(entry, "tags_any"), :tag, org_id)
    category = live_ids(List.wrap(Map.get(entry, "category")), :category, org_id)

    fields =
      case Map.get(entry, "fields") do
        %{} = fields ->
          Map.take(fields, live_field_names(Map.keys(fields), descriptor, org_id))

        _none ->
          %{}
      end

    kept =
      %{}
      |> put_unless_empty("tags_any", tags)
      |> put_unless_empty("category", List.first(category))
      |> put_unless_empty("fields", fields)

    if kept == %{}, do: nil, else: kept
  end

  defp live_entry(_entry, _descriptor, _org_id), do: nil

  defp put_unless_empty(map, _key, value) when value in [nil, [], %{}], do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)

  @doc """
  The field names, across every reference definition of the org, that
  selections name for `type` — `{definition, [names]}` pairs. The guard
  against making such a field private, or retyping it, reads this.
  """
  @spec named_fields(String.t(), term()) :: [{FieldDefinition.t(), [String.t()]}]
  def named_fields(type, tenant) do
    [
      actor: KilnCMS.CMS.Housekeeping.system(:cms_registry),
      authorize_with: :error,
      tenant: KilnCMS.Accounts.org_id(tenant),
      query: [filter: [field_type: :reference, selection: [is_nil: false]]]
    ]
    |> CMS.list_field_definitions!()
    |> Enum.flat_map(fn definition ->
      names =
        case normalize(definition.selection) do
          %{"by_type" => %{^type => %{"fields" => %{} = fields}}} -> Map.keys(fields)
          _other -> []
        end

      if names == [], do: [], else: [{definition, names}]
    end)
  end
end
