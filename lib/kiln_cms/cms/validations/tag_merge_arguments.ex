defmodule KilnCMS.CMS.Validations.TagMergeArguments do
  @moduledoc """
  Guards the three tag-writing arguments on `:update` against combinations
  whose outcome would depend on the order the `manage_relationship` changes
  happen to be declared in (#521).

    * `tag_ids` is the *complete* set (append-and-remove). Combining it with
      either merge verb is refused rather than silently resolved — a caller
      that sends both has two different intents in one request.
    * The same id in `add_tag_ids` and `remove_tag_ids` is refused for the
      same reason: the manages run in declaration order, so the answer would
      be "removed", which is not obviously what the caller meant.

  The two sides read presence differently, and the asymmetry is the whole
  point of `replacing?/1` vs `merging/2`:

    * `tag_ids` is **replacing** whenever it was supplied *at all*, explicit
      `null` included. Ash's `manage_relationship` treats `{:ok, nil}` as the
      supplied branch and `List.wrap`s it to `[]`, so `tag_ids: null` clears
      every tag exactly like `tag_ids: []` does. Reading `null` as "absent"
      here would let the single most common client shape — a generated
      SDK that serializes unset fields as `null` — walk past this guard and
      silently detach, which is precisely the bug #521 exists to close.
    * A merge verb is only **merging** when it carries at least one id. `null`
      and `[]` are both no-ops with nothing to conflict with, so a client that
      fills every field in the input schema (equally common) is not locked out
      of the replace path by two empty arrays.

  Nothing else is checked here — an unknown id in `add_tag_ids` is rejected by
  `manage_relationship`'s own lookup (`on_no_match: :error`), and an id in
  `remove_tag_ids` that is not currently attached is deliberately a no-op so
  removal stays idempotent. Repeated ids within one list are de-duplicated
  upstream by `KilnCMS.CMS.Changes.NormalizeTagArguments`, not rejected here.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidArgument

  @impl true
  def validate(changeset, _opts, _context) do
    add = merging(changeset, :add_tag_ids)
    remove = merging(changeset, :remove_tag_ids)

    cond do
      add == [] and remove == [] ->
        :ok

      replacing?(changeset) ->
        error(:tag_ids, add, remove, "cannot be combined with #{verbs(add, remove)}")

      not MapSet.disjoint?(MapSet.new(add), MapSet.new(remove)) ->
        error(:remove_tag_ids, add, remove, "cannot list the same tag as add_tag_ids")

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
       value: %{add_tag_ids: add, remove_tag_ids: remove},
       message: message
     )}
  end

  defp verbs([], _remove), do: "remove_tag_ids"
  defp verbs(_add, []), do: "add_tag_ids"
  defp verbs(_add, _remove), do: "add_tag_ids or remove_tag_ids"

  # Supplied at all — including an explicit `null`, which clears.
  defp replacing?(changeset),
    do: match?({:ok, _}, Ash.Changeset.fetch_argument(changeset, :tag_ids))

  # Carrying at least one id; `null` and `[]` are no-ops.
  defp merging(changeset, argument) do
    case Ash.Changeset.fetch_argument(changeset, argument) do
      {:ok, ids} when is_list(ids) -> ids
      _ -> []
    end
  end
end
