defmodule KilnCMS.CMS.Preparations.CustomFieldQuery.Relations do
  @moduledoc """
  The relationship operators of `custom_filter` (workstream R6 of
  `docs/relationships-plan.md`): `has` (any of), `has_all`, `has_none` and
  `count`, on a `:reference` custom field and on the built-in `tags` and
  `related_<type>s` relationships.

  A reference field's operators compile to `exists` (or a `count`) over the
  record's outgoing `content_links` edges — `kind: :reference`, the field's
  name, the target id — which the `(org_id, source_id, target_id, kind,
  field)` identity index serves. They never scan the jsonb snapshot. `eq` and
  `in` keep their snapshot meaning (`CustomFieldQuery`).

  ## Who may see a match

  An edge is only visible to a reader who may read both of its ends
  (`KilnCMS.CMS.Checks.LinkEndsReadable`). The source is the record being
  filtered, which the read policy already gates. The target is gated here:
  every edge condition carries `exists(<target resource>, id ==
  parent(target_id) and <the reader's read filter on it>)`, the filter
  being the one `Ash.can/3` derives from the target resource's own read
  policy for this actor — so it cannot drift from it, and a filter cannot be
  used to learn that a draft target exists. A draft-only match returns
  nothing to an anonymous reader and the record to an editor; `count` counts
  only the targets the reader could open; `has_none` of a target the reader
  cannot see is true, as if it were not there.

  The filter is built from the query's actor whether or not the read itself
  is authorized: a delivery read that runs `authorize?: false` and carries no
  actor is gated as an anonymous reader, never as nobody-checked.

  Tags are world-readable taxonomy (D7) and need no gate.
  """

  import Ash.Expr

  alias KilnCMS.CMS.ContentTypes

  @operators ~w(has has_all has_none count)
  @count_operators ~w(eq gt gte lt lte)

  # A bound on the ids one operator takes: each id of `has_all` is its own
  # `exists`, and a query string is no place for an unbounded list.
  @max_ids 100

  @doc "The operators this module answers."
  @spec operators() :: [String.t()]
  def operators, do: @operators

  @doc "The most ids one `has` / `has_all` / `has_none` accepts."
  @spec max_ids() :: pos_integer()
  def max_ids, do: @max_ids

  @doc """
  The built-in relationship `name` names on `resource` that these operators
  apply to, or nil: `"tags"`, or the resource's own `"related_<type>s"`.
  """
  @spec builtin(module(), String.t()) :: {:tags | :related, atom()} | nil
  def builtin(resource, name) do
    with %{type: :many_to_many, name: rel} <- relationship(resource, name) do
      cond do
        rel == :tags -> {:tags, rel}
        String.starts_with?(name, "related_") -> {:related, rel}
        true -> nil
      end
    end
  end

  defp relationship(resource, name) do
    resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(Atom.to_string(&1.name) == name))
  end

  @doc """
  The expression for one relationship operator on a `:reference` field
  definition, or `{:error, message}`. `ctx` carries `:resource`, `:actor` and
  `:tenant`.
  """
  @spec reference(map(), String.t(), term(), map()) :: {:ok, term()} | {:error, String.t()}
  def reference(%{name: name} = definition, op, raw, ctx) do
    edge = fn extra ->
      readable = readable_target(target_resources(definition, ctx), ctx)
      expr(kind == :reference and field == ^name and ^readable and ^extra)
    end

    operator(op, raw, name, edge)
  end

  @doc """
  The expression for a link-field filter (R3): the record has **some**
  `:reference` edge of `definition`'s field whose target the reader may read
  and whose `metadata` satisfies `condition` (built over the edge by
  `CustomFieldQuery`). The same edge and the same gate as `has`.

  `targets` ties the condition to the edges pointing at those ids (#2044):
  "this person is the photographer", rather than "someone is". `nil` — any
  edge of the field — is what a link filter always meant.
  """
  @spec link(map(), term(), map(), [Ash.UUID.t()] | nil) :: term()
  def link(%{name: name} = definition, condition, ctx, targets \\ nil) do
    readable = readable_target(target_resources(definition, ctx), ctx)
    on_targets = if targets, do: expr(target_id in ^targets), else: expr(true)

    expr(
      exists(
        content_links,
        kind == :reference and field == ^name and ^on_targets and ^readable and ^condition
      )
    )
  end

  @doc """
  The ids of a link filter's `target` (#2044): one id or a list, at most
  `max_ids/0`, each a UUID. `label` names the filter in the error.
  """
  @spec link_targets(term(), String.t()) :: {:ok, [Ash.UUID.t()]} | {:error, String.t()}
  def link_targets(raw, label), do: ids(raw, label, "target")

  @doc """
  The expression for one relationship operator on a built-in relationship
  (`builtin/2`'s result), or `{:error, message}`.
  """
  @spec builtin_condition({:tags | :related, atom()}, String.t(), term(), map()) ::
          {:ok, term()} | {:error, String.t()}
  def builtin_condition({:tags, _rel}, op, raw, _ctx) when op in ~w(has has_all has_none) do
    with {:ok, ids} <- ids(raw, "tags", op) do
      {:ok, tags_condition(op, ids)}
    end
  end

  # `related_<type>s` is the `kind: :related` rows with no `field`
  # (`KilnCMS.CMS.RelatedLink`'s base filter), so the same rule applies here.
  # Its destination is the resource itself.
  def builtin_condition({:related, rel}, op, raw, ctx) when op in ~w(has has_all has_none) do
    edge = fn extra ->
      readable = readable_target([ctx.resource], ctx)
      expr(kind == :related and is_nil(field) and ^readable and ^extra)
    end

    operator(op, raw, Atom.to_string(rel), edge)
  end

  def builtin_condition({_kind, rel}, op, _raw, _ctx) do
    {:error, "#{rel} only supports has/has_all/has_none (got #{inspect(op)})"}
  end

  # --- operators ----------------------------------------------------------------

  # `edge.(extra)` is the condition on one `content_links` row: its kind and
  # field, the reader's gate on the target, and `extra`.
  defp operator(op, raw, name, edge) when op in ~w(has has_all has_none) do
    with {:ok, ids} <- ids(raw, name, op) do
      {:ok, edge_condition(op, ids, edge)}
    end
  end

  defp operator("count", raw, name, edge) do
    with {:ok, comparisons} <- count_comparisons(raw, name) do
      linked = edge.(true)

      comparisons
      |> Enum.map(fn {cmp, n} ->
        # Ash would authorize the aggregate against `ContentLink`'s read
        # policy, whose both-ends check is a runtime one it cannot fold into
        # SQL, so it refuses the read.
        # authorize?: false — `linked` already carries the both-ends gate (moduledoc).
        count =
          expr(count(content_links, query: [filter: expr(^linked)], authorize?: false))

        compare(cmp, count, n)
      end)
      |> Enum.reduce(&expr(^&2 and ^&1))
      |> then(&{:ok, &1})
    end
  end

  defp edge_condition("has", ids, edge) do
    linked = edge.(expr(target_id in ^ids))
    expr(exists(content_links, ^linked))
  end

  defp edge_condition("has_none", ids, edge) do
    expr(not (^edge_condition("has", ids, edge)))
  end

  # One `exists` per id: each is an index probe, where a `count(DISTINCT
  # target_id) = n` would aggregate every matching edge.
  defp edge_condition("has_all", ids, edge) do
    ids
    |> Enum.map(fn id ->
      linked = edge.(expr(target_id == ^id))
      expr(exists(content_links, ^linked))
    end)
    |> Enum.reduce(&expr(^&2 and ^&1))
  end

  defp tags_condition("has", ids), do: expr(exists(tags, id in ^ids))
  defp tags_condition("has_none", ids), do: expr(not exists(tags, id in ^ids))

  defp tags_condition("has_all", ids) do
    ids
    |> Enum.map(&expr(exists(tags, id == ^&1)))
    |> Enum.reduce(&expr(^&2 and ^&1))
  end

  defp compare("eq", count, n), do: expr(^count == ^n)
  defp compare("gt", count, n), do: expr(^count > ^n)
  defp compare("gte", count, n), do: expr(^count >= ^n)
  defp compare("lt", count, n), do: expr(^count < ^n)
  defp compare("lte", count, n), do: expr(^count <= ^n)

  # --- the reader's gate on the target --------------------------------------------

  # The resources a field's targets live in. One type today (`target_type`);
  # `target_types` (R2) lists several. A name that no longer resolves falls
  # back to every content resource, like `LinkEndsReadable`.
  defp target_resources(definition, ctx) do
    names =
      case Map.get(definition, :target_types) do
        [_ | _] = names -> names
        _ -> List.wrap(Map.get(definition, :target_type))
      end

    resolved = Enum.map(names, &resource_for(&1, ctx.tenant))

    if names == [] or Enum.any?(resolved, &is_nil/1),
      do: all_resources(),
      else: Enum.uniq(resolved)
  end

  defp resource_for(name, tenant) do
    case ContentTypes.get(name, tenant) do
      %{source: :dynamic} -> KilnCMS.CMS.Entry
      %{resource: resource} when is_atom(resource) and not is_nil(resource) -> resource
      _ -> nil
    end
  end

  defp all_resources do
    ContentTypes.blocks_resources() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
  end

  # True when the edge's target is a row of one of `resources` the reader may
  # read: an unrelated `exists` carrying the read filter `Ash.can/3` derives
  # from that resource's policy for this actor (what Ash itself applies to an
  # unrelated `exists` written in a caller's filter).
  #
  # `IS TRUE` changes nothing about the value (it is never NULL) and
  # everything about the plan. A bare `EXISTS` in the edge condition is
  # pulled up into a join, and inside `count`'s per-record LATERAL Postgres
  # then re-hashed every readable target once per record: 5.3 s to scan
  # 20,000 posts over 600k edges. Wrapped, it stays a subplan, which
  # Postgres hashes once per query and probes per edge: 135 ms for the same
  # scan (R6 in `docs/relationships-plan.md`).
  defp readable_target(resources, ctx) do
    resources
    |> Enum.map(fn resource ->
      case read_filter(resource, ctx) do
        false -> expr(false)
        filter -> unrelated_exists(resource, expr(id == parent(target_id) and ^filter))
      end
    end)
    |> Enum.reduce(&expr(^&2 or ^&1))
    |> then(&expr(fragment("(?) IS TRUE", ^&1)))
  end

  # `exists(Resource, …)` with the resource known only at runtime: the struct
  # the `expr` macro builds for a literal module.
  defp unrelated_exists(resource, condition) do
    %Ash.Query.Exists{path: [], resource: resource, expr: condition, at_path: [], related?: false}
  end

  # In-memory (`run_queries?: false`): one policy evaluation per target
  # resource and condition, no query.
  defp read_filter(resource, %{actor: actor, tenant: tenant}) do
    action = Ash.Resource.Info.primary_action!(resource, :read)

    query =
      Ash.Query.for_read(resource, action.name, %{},
        actor: actor,
        tenant: tenant,
        authorize?: true
      )

    case Ash.can(query, actor,
           run_queries?: false,
           pre_flight?: false,
           alter_source?: true,
           no_check?: true,
           return_forbidden_error?: true,
           maybe_is: false
         ) do
      {:ok, true, %{filter: nil}} -> true
      {:ok, true, %{filter: %Ash.Filter{expression: expression}}} -> expression
      {:ok, true} -> true
      # Refused outright, or not decidable as a filter: no target is
      # readable. Denying is the safe direction for a read.
      _ -> false
    end
  end

  # --- input ------------------------------------------------------------------------

  defp ids(raw, name, op) do
    raw = if is_binary(raw), do: [raw], else: raw

    cond do
      not is_list(raw) ->
        {:error, "#{op} for #{inspect(name)} takes an id or a list of ids"}

      raw == [] ->
        {:error, "#{op} for #{inspect(name)} needs at least one id"}

      length(raw) > @max_ids ->
        {:error, "#{op} for #{inspect(name)} takes at most #{@max_ids} ids"}

      true ->
        cast_ids(raw, name, op)
    end
  end

  defp cast_ids(raw, name, op) do
    raw
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case Ash.Type.cast_input(:uuid, item) do
        {:ok, id} when is_binary(id) -> {:cont, {:ok, [id | acc]}}
        _ -> {:halt, {:error, "#{op} for #{inspect(name)}: #{inspect(item)} is not an id"}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, ids |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  # A bare number is `eq`; a map holds `eq`/`gt`/`gte`/`lt`/`lte`.
  defp count_comparisons(raw, name) when not is_map(raw),
    do: count_comparisons(%{"eq" => raw}, name)

  defp count_comparisons(raw, name) when map_size(raw) == 0,
    do: {:error, "count for #{inspect(name)} needs a comparison (eq/gt/gte/lt/lte)"}

  defp count_comparisons(raw, name) do
    Enum.reduce_while(raw, {:ok, []}, fn {cmp, value}, {:ok, acc} ->
      case count_comparison(to_string(cmp), value, name) do
        {:ok, comparison} -> {:cont, {:ok, [comparison | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  defp count_comparison(cmp, _value, name) when cmp not in @count_operators do
    {:error, "unknown count comparison #{inspect(cmp)} for #{inspect(name)} (eq/gt/gte/lt/lte)"}
  end

  defp count_comparison(cmp, value, name) do
    case count_value(value) do
      {:ok, n} -> {:ok, {cmp, n}}
      :error -> {:error, "count for #{inspect(name)} takes a whole number ≥ 0"}
    end
  end

  defp count_value(n) when is_integer(n) and n >= 0, do: {:ok, n}

  defp count_value(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp count_value(_raw), do: :error
end
