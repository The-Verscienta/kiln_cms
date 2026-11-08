defmodule KilnCMSWeb.CustomFieldAliases do
  @moduledoc """
  Lets an admin-defined custom field be named the way a column is on the
  JSON:API index routes: `filter[price][gt]=10` and `sort=-price` mean what
  `custom_filter[price][gt]=10` and `custom_sort=-price` do (#2292).

  `ash_json_api` parses `filter[...]` and `sort=` against the resource's
  public fields *before* the read action runs, and answers 400 for a name it
  does not know, so `KilnCMS.CMS.Preparations.CustomFieldQuery` (the engine
  behind `custom_filter` / `custom_sort`) never sees such a name. This module
  runs earlier — as the router's `before_dispatch` — and rewrites
  `conn.query_params` so the name arrives where the engine reads it.

  It is **purely lexical**. It reads no registry, checks no tier and parses no
  Entry scope: whether a field exists, and whether the caller may see it, stays
  the preparation's decision alone. So a private field and an unknown one reach
  the same code and answer with the same message. It also never answers a
  request itself — `before_dispatch`'s result goes straight to the controller
  with no `halted` check — so wherever a rewrite would have to be refused, the
  parameter is left as written and `ash_json_api` rejects it natively.

  ## Rules

    * Acts on a matched `:index` route only, and each half separately: `filter`
      when the action declares a `:custom_filter` argument, `sort` when it
      declares `:custom_sort`. Anything else (get-by-id, relationship routes,
      writes) is untouched.
    * A **built-in** name always wins and keeps its meaning. For `filter[x]` that
      is a public attribute, calculation, aggregate or relationship (or
      `and` / `or` / `not`); for `sort=x` a public attribute, calculation or
      aggregate. Membership counts even if the built-in cannot be filtered or
      sorted, so `filter[path]` and `sort=word_count` keep their 400s.
    * Any other name moves: `filter[x]` becomes `custom_filter[x]`, each `sort`
      token becomes a `custom_sort` token. `custom_filter` / `custom_sort`
      themselves still always mean a custom field (the escape hatch for a field
      named like a column).
    * `filter[tags][has]` and the other relationship operators
      (`has` / `has_all` / `has_none` / `count`) on the built-in relations
      `tags` and `related_<type>s` move; `filter[tags][slug]` stays native.
    * `filter[x]` and `custom_filter[x]` together: for a built-in `x` both apply
      (ANDed); otherwise they merge into one `custom_filter[x]`, and a clash on
      an operator leaves `filter[x]` as written (a native 400).
    * Built-in tokens that lead `sort` stay in it; from the first custom token
      on, every token moves to `custom_sort` in order, a built-in one spelled
      `_native:<name>` there (#2356), so `sort=price,title` is one order, price
      then title. Tokens moved out of `sort` go before an explicit `custom_sort`.
    * `filter[or]` / `[and]` / `[not]` stay native while every name in them is a
      built-in. When any condition inside names a custom field (at any depth) the
      whole group moves to `custom_filter[_or]` / `[_and]` / `[_not]`, its
      built-in names collected under `_native` in each member (#2355). If
      `custom_filter` already has that group key, `filter` is left as written (a
      native 400).

  `resolve/2` and `builtin_filter_name?/2` / `builtin_sort_name?/2` are the
  reusable half: they classify one name against a resource, with no request in
  sight.
  """

  alias AshJsonApi.Resource.Info, as: JsonApi
  alias KilnCMS.CMS.Preparations.CustomFieldQuery.Relations

  @logic_keys ~w(and or not)
  @relation_operators Relations.operators()

  @doc """
  `before_dispatch` entry point (`KilnCMSWeb.AshJsonApiRouter`). `ash_json_api`
  also calls it with `:open_api`, `:json_schema` and `:not_found`; those pass
  through.
  """
  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(conn, %{resource: resource, route: %{type: :index} = route}) do
    %{conn | query_params: rewrite(conn.query_params, resource, route)}
  end

  def call(conn, _route_info), do: conn

  @doc """
  The query parameters with custom-field names in `filter` / `sort` moved to
  `custom_filter` / `custom_sort`, per the module doc. Pure.
  """
  @spec rewrite(map(), module(), map()) :: map()
  def rewrite(query_params, resource, %{type: :index} = route) when is_map(query_params) do
    action = Ash.Resource.Info.action(resource, route.action)

    query_params
    |> rewrite_filter(resource, route, action)
    |> rewrite_sort(resource, route, action)
  end

  def rewrite(query_params, _resource, _route), do: query_params

  @doc """
  Whether `name` is a built-in `filter[...]` head on `resource`: a public
  attribute, calculation, aggregate or relationship, or `and` / `or` / `not`.
  """
  @spec builtin_filter_name?(module(), String.t()) :: boolean()
  def builtin_filter_name?(resource, name) do
    name in @logic_keys or name in public_names(resource, :filter)
  end

  @doc """
  Whether `name` is a built-in `sort` field on `resource`: a public attribute,
  calculation or aggregate.
  """
  @spec builtin_sort_name?(module(), String.t()) :: boolean()
  def builtin_sort_name?(resource, name), do: name in public_names(resource, :sort)

  @doc """
  What a `filter` / `sort` name means on `resource`: `:builtin`, or `:custom`
  when it is neither a built-in nor blank (a custom field *if* the registry
  has it — this module never looks).
  """
  @spec resolve(module(), :filter | :sort, String.t()) :: :builtin | :custom
  def resolve(resource, :filter, name) do
    if builtin_filter_name?(resource, name), do: :builtin, else: :custom
  end

  def resolve(resource, :sort, name) do
    if String.trim(name) == "" or builtin_sort_name?(resource, name),
      do: :builtin,
      else: :custom
  end

  # --- filter -------------------------------------------------------------------

  defp rewrite_filter(params, resource, route, action) do
    with true <- has_argument?(action, :custom_filter),
         true <- derives?(route, resource, :filter),
         {:ok, filter} <- filter_map(params["filter"]),
         {:ok, custom} <- custom_filter_map(params["custom_filter"]) do
      {kept, custom} =
        Enum.reduce(filter, {%{}, custom}, fn {name, value}, {kept, custom} ->
          move_filter(resource, name, value, kept, custom)
        end)

      if kept == filter do
        params
      else
        params
        |> put_or_delete("filter", kept)
        |> put_or_delete("custom_filter", custom)
      end
    else
      _ -> params
    end
  end

  # A string-form filter (`?filter=price%3D10`) is decoded the way
  # `ash_json_api` decodes it, so the alias doesn't depend on the encoding.
  defp filter_map(filter) when is_map(filter), do: {:ok, filter}

  defp filter_map(filter) when is_binary(filter) do
    {:ok, Plug.Conn.Query.decode(filter)}
  rescue
    _ in [Plug.Conn.InvalidQueryError, ArgumentError] -> :error
  end

  defp filter_map(_), do: :error

  defp custom_filter_map(nil), do: {:ok, %{}}
  defp custom_filter_map(map) when is_map(map), do: {:ok, map}
  defp custom_filter_map(_), do: :error

  # -> {kept in `filter`, `custom_filter` so far}
  defp move_filter(resource, name, value, kept, custom) do
    name = to_string(name)

    cond do
      name in @logic_keys ->
        move_group(resource, name, value, kept, custom)

      builtin_filter_name?(resource, name) ->
        move_relation_operators(resource, name, value, kept, custom)

      true ->
        case merge_condition(custom, name, value) do
          {:ok, custom} -> {kept, custom}
          :conflict -> {Map.put(kept, name, value), custom}
        end
    end
  end

  # `filter[tags][has]` never parses natively (a relationship takes field
  # filters, not set operators), so moving the operator keys is additive. The
  # rest of the condition (`filter[tags][slug]`) stays where it is.
  defp move_relation_operators(resource, name, value, kept, custom) when is_map(value) do
    with {_, _} <- Relations.builtin(resource, name),
         {moving, staying} when moving != %{} <-
           Map.split(value, @relation_operators),
         {:ok, custom} <- merge_condition(custom, name, moving) do
      {put_unless_empty(kept, name, staying), custom}
    else
      _ -> {Map.put(kept, name, value), custom}
    end
  end

  defp move_relation_operators(_resource, name, value, kept, custom),
    do: {Map.put(kept, name, value), custom}

  # --- groups (#2355) -----------------------------------------------------------

  defp move_group(resource, name, value, kept, custom) do
    key = "_" <> name

    with true <- group_moves?(resource, name, value),
         false <- Map.has_key?(custom, key),
         {:ok, converted} <- convert_group(resource, name, value) do
      {kept, Map.put(custom, key, converted)}
    else
      _ -> {Map.put(kept, name, value), custom}
    end
  end

  # Whether a group names something only `custom_filter` can answer: a custom
  # field, or a relationship operator (`tags[has]`), at any depth.
  defp group_moves?(resource, name, value) do
    case group_members(name, value) do
      {:ok, members} -> Enum.any?(members, &member_moves?(resource, &1))
      :error -> false
    end
  end

  defp member_moves?(resource, member) do
    Enum.any?(member, fn {name, value} ->
      name = to_string(name)

      cond do
        name in @logic_keys -> group_moves?(resource, name, value)
        builtin_filter_name?(resource, name) -> relation_operators?(resource, name, value)
        true -> true
      end
    end)
  end

  defp relation_operators?(resource, name, value) when is_map(value) do
    match?({_, _}, Relations.builtin(resource, name)) and
      Enum.any?(Map.keys(value), &(to_string(&1) in @relation_operators))
  end

  defp relation_operators?(_resource, _name, _value), do: false

  # `or` / `and` take a list of members or a position-keyed map of them; `not`
  # takes one member.
  defp group_members("not", value) when is_map(value) and map_size(value) > 0, do: {:ok, [value]}

  defp group_members(name, value) when name in ["or", "and"] and is_list(value),
    do: if(value != [] and Enum.all?(value, &is_map/1), do: {:ok, value}, else: :error)

  defp group_members(name, value) when name in ["or", "and"] and is_map(value) do
    ordered =
      Enum.map(value, fn {key, member} ->
        case Integer.parse(to_string(key)) do
          {position, ""} -> {position, member}
          _ -> :error
        end
      end)

    if :error in ordered or ordered == [] do
      :error
    else
      ordered
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))
      |> then(&group_members(name, &1))
    end
  end

  defp group_members(_name, _value), do: :error

  defp convert_group(resource, "not", value) do
    with {:ok, [member]} <- group_members("not", value), do: convert_member(resource, member)
  end

  defp convert_group(resource, name, value) do
    with {:ok, members} <- group_members(name, value) do
      members
      |> Enum.reduce_while({:ok, []}, &reduce_member(resource, &1, &2))
      |> then(fn
        {:ok, converted} -> {:ok, Enum.reverse(converted)}
        :error -> :error
      end)
    end
  end

  defp reduce_member(resource, member, {:ok, acc}) do
    case convert_member(resource, member) do
      {:ok, converted} -> {:cont, {:ok, [converted | acc]}}
      :error -> {:halt, :error}
    end
  end

  # One member: custom names (and nested groups that hold some) stay as
  # `custom_filter` conditions, built-in names gather under `_native`.
  defp convert_member(resource, member) do
    member
    |> Enum.reduce_while({:ok, {%{}, %{}}}, &reduce_entry(resource, &1, &2))
    |> then(fn
      {:ok, {native, custom}} -> {:ok, put_unless_empty(custom, "_native", native)}
      :error -> :error
    end)
  end

  defp reduce_entry(resource, {name, value}, {:ok, {native, custom}}) do
    name = to_string(name)

    if name in @logic_keys and group_moves?(resource, name, value) do
      case convert_group(resource, name, value) do
        {:ok, converted} -> {:cont, {:ok, {native, Map.put(custom, "_" <> name, converted)}}}
        :error -> {:halt, :error}
      end
    else
      {:cont, {:ok, move_filter_into_member(resource, name, value, native, custom)}}
    end
  end

  # A logic key that holds only built-ins stays native, like any built-in name.
  defp move_filter_into_member(resource, name, value, native, custom) do
    if name in @logic_keys do
      {Map.put(native, name, value), custom}
    else
      move_filter(resource, name, value, native, custom)
    end
  end

  defp put_unless_empty(map, _key, value) when value == %{}, do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)

  # Adds `value` under `name` in the custom filter. An existing entry for the
  # same name merges (a bare value is `eq`); a repeated operator is a conflict.
  defp merge_condition(custom, name, value) do
    case Map.fetch(custom, name) do
      :error ->
        {:ok, Map.put(custom, name, value)}

      {:ok, existing} ->
        left = as_condition(existing)
        right = as_condition(value)

        if Map.keys(left) -- Map.keys(right) == Map.keys(left) do
          {:ok, Map.put(custom, name, Map.merge(left, right))}
        else
          :conflict
        end
    end
  end

  defp as_condition(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp as_condition(value), do: %{"eq" => value}

  # --- sort ---------------------------------------------------------------------

  defp rewrite_sort(params, resource, route, action) do
    with true <- has_argument?(action, :custom_sort),
         true <- derives?(route, resource, :sort),
         sort when is_binary(sort) <- params["sort"],
         {:ok, existing} <- existing_custom_sort(params["custom_sort"]) do
      case split_sort(resource, sort) do
        :keep ->
          params

        {builtin, moved} ->
          params
          |> put_or_delete("sort", join_tokens(builtin))
          |> put_or_delete("custom_sort", join_tokens(moved ++ existing))
      end
    else
      _ -> params
    end
  end

  # `{built-in tokens, custom tokens}`, or `:keep` when there is nothing to move.
  # The built-ins that lead stay in `sort`; everything from the first custom
  # token on moves, a later built-in one marked `_native:` so it keeps its place
  # in the order (#2356).
  defp split_sort(resource, sort) do
    classified = sort |> String.split(",") |> Enum.map(&{&1, classify_sort_token(resource, &1)})
    {builtin, rest} = Enum.split_while(classified, fn {_, kind} -> kind == :builtin end)

    if rest == [] or Enum.any?(rest, fn {token, _} -> blank_token?(token) end) do
      :keep
    else
      {Enum.map(builtin, &elem(&1, 0)), Enum.map(rest, &custom_sort_token/1)}
    end
  end

  # A blank token is left for `ash_json_api`'s own error.
  defp blank_token?(token),
    do: token |> String.trim() |> String.trim_leading("-") |> String.trim() == ""

  defp custom_sort_token({token, :custom}), do: String.trim(token)

  defp custom_sort_token({token, :builtin}) do
    case token |> String.trim() |> String.trim_leading() do
      "-" <> name -> "-_native:" <> String.trim(name)
      name -> "_native:" <> name
    end
  end

  defp existing_custom_sort(nil), do: {:ok, []}

  defp existing_custom_sort(sort) when is_binary(sort),
    do: {:ok, if(String.trim(sort) == "", do: [], else: [sort])}

  defp existing_custom_sort(_), do: :error

  defp classify_sort_token(resource, token) do
    # Trimmed the way `CustomFieldQuery` trims a `custom_sort` token; a blank
    # one is left for `ash_json_api`'s own error.
    name = token |> String.trim() |> String.trim_leading("-") |> String.trim()
    resolve(resource, :sort, name)
  end

  defp join_tokens([]), do: nil
  defp join_tokens(tokens), do: Enum.join(tokens, ",")

  # --- shared -------------------------------------------------------------------

  defp put_or_delete(params, key, empty) when empty in [nil, %{}], do: Map.delete(params, key)
  defp put_or_delete(params, key, value), do: Map.put(params, key, value)

  defp has_argument?(%{arguments: arguments}, name),
    do: Enum.any?(arguments, &(&1.name == name))

  defp has_argument?(_action, _name), do: false

  defp derives?(route, resource, :filter),
    do: route.derive_filter? != false and JsonApi.derive_filter?(resource) != false

  defp derives?(route, resource, :sort),
    do: route.derive_sort? != false and JsonApi.derive_sort?(resource) != false

  # The names `ash_json_api` accepts, as it spells them on the wire.
  defp public_names(resource, kind) do
    mapping = JsonApi.field_names(resource)

    fields =
      Ash.Resource.Info.public_attributes(resource) ++
        Ash.Resource.Info.public_calculations(resource) ++
        Ash.Resource.Info.public_aggregates(resource) ++
        if(kind == :filter, do: Ash.Resource.Info.public_relationships(resource), else: [])

    fields
    |> Enum.flat_map(fn %{name: name} ->
      [Atom.to_string(name), JsonApi.apply_field_name_mapping(mapping, name)]
    end)
    |> Enum.uniq()
  end
end
