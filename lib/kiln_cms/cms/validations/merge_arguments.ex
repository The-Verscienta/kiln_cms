defmodule KilnCMS.CMS.Validations.MergeArguments do
  @moduledoc """
  Guards a group of three relationship-writing arguments against combinations
  whose outcome would depend on the order the `manage_relationship` changes
  happen to be declared in (#521, generalized in #637).

  A group is a complete-set argument (`type: :append_and_remove`) and its two
  merge verbs — an `append` add and an `unrelate` remove. Parameterized so one
  validation covers every such group rather than a bespoke module per
  relationship: tags (`tag_ids` / `add_tag_ids` / `remove_tag_ids`) and each
  related-content array (`related_post_ids` / `add_related_post_ids` /
  `remove_related_post_ids`, and the siblings for pages and entries).

      validate {MergeArguments,
        complete: :tag_ids, add: :add_tag_ids, remove: :remove_tag_ids}

  Two combinations are refused, and the asymmetry between them is the whole
  point of `replacing?/2` vs `merging/2`:

    * The complete-set argument is **replacing** whenever it was supplied *at
      all*, explicit `null` included. Ash's `manage_relationship` treats
      `{:ok, nil}` as the supplied branch and `List.wrap`s it to `[]`, so
      `…_ids: null` clears every link exactly like `…_ids: []` does. Reading
      `null` as "absent" would let the single most common client shape — a
      generated SDK that serializes unset fields as `null` — walk past this
      guard and silently detach, which is the bug #521/#637 exist to close. So
      combining it with either merge verb is refused rather than resolved by
      declaration order.

    * A merge verb is only **merging** when it carries at least one id. `null`
      and `[]` are both no-ops with nothing to conflict with, so a client that
      fills every field in the input schema is not locked out of the replace
      path by two empty arrays. The same id in both verbs is refused for the
      same reason as above: the manages run in declaration order, so the answer
      would be "removed", which is not obviously what the caller meant.

  Nothing else is checked here — an unknown id in the add verb is rejected by
  `manage_relationship`'s own lookup (`on_no_match: :error`), and an id in the
  remove verb that is not attached is a deliberate idempotent no-op. Repeated
  ids within one list are de-duplicated upstream by
  `KilnCMS.CMS.Changes.NormalizeManagedArguments`, not rejected here.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidArgument

  @impl true
  def init(opts) do
    with :ok <- require_atom(opts, :complete),
         :ok <- require_atom(opts, :add),
         :ok <- require_atom(opts, :remove) do
      {:ok, opts}
    end
  end

  defp require_atom(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_atom(value) and not is_nil(value) -> :ok
      _ -> {:error, "#{inspect(key)} must be an argument name (atom)"}
    end
  end

  @impl true
  def validate(changeset, opts, _context) do
    add = merging(changeset, opts[:add])
    remove = merging(changeset, opts[:remove])

    cond do
      add == [] and remove == [] ->
        :ok

      replacing?(changeset, opts[:complete]) ->
        error(opts[:complete], add, remove, "cannot be combined with #{verbs(opts, add, remove)}")

      not MapSet.disjoint?(MapSet.new(add), MapSet.new(remove)) ->
        error(opts[:remove], add, remove, "cannot list the same id as #{opts[:add]}")

      true ->
        :ok
    end
  end

  # `value:` is not decoration: `InvalidArgument.message/1` interpolates it
  # unconditionally, so omitting it appends a bare "nil" to the rendered
  # message — and `Exception.message/1` is what AshAi hands back to the model
  # on a rejected MCP tool call, the surface this whole change is written for.
  defp error(field, add, remove, message) do
    {:error,
     InvalidArgument.exception(
       field: field,
       value: %{add: add, remove: remove},
       message: message
     )}
  end

  defp verbs(opts, [], _remove), do: to_string(opts[:remove])
  defp verbs(opts, _add, []), do: to_string(opts[:add])
  defp verbs(opts, _add, _remove), do: "#{opts[:add]} or #{opts[:remove]}"

  # Supplied at all — including an explicit `null`, which clears.
  defp replacing?(changeset, complete),
    do: match?({:ok, _}, Ash.Changeset.fetch_argument(changeset, complete))

  # Carrying at least one id; `null` and `[]` are no-ops.
  defp merging(changeset, argument) do
    case Ash.Changeset.fetch_argument(changeset, argument) do
      {:ok, ids} when is_list(ids) -> ids
      _ -> []
    end
  end
end
