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

  Nothing else is checked here — an unknown id in `add_tag_ids` is rejected by
  `manage_relationship`'s own lookup (`on_no_match: :error`), and an id in
  `remove_tag_ids` that is not currently attached is deliberately a no-op so
  removal stays idempotent.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidArgument

  @impl true
  def validate(changeset, _opts, _context) do
    add = supplied(changeset, :add_tag_ids)
    remove = supplied(changeset, :remove_tag_ids)

    cond do
      is_nil(add) and is_nil(remove) ->
        :ok

      not is_nil(supplied(changeset, :tag_ids)) ->
        {:error,
         InvalidArgument.exception(
           field: :tag_ids,
           message: "cannot be combined with add_tag_ids or remove_tag_ids"
         )}

      true ->
        overlap(add || [], remove || [])
    end
  end

  defp overlap(add, remove) do
    if MapSet.disjoint?(MapSet.new(add), MapSet.new(remove)) do
      :ok
    else
      {:error,
       InvalidArgument.exception(
         field: :remove_tag_ids,
         message: "cannot list the same tag as add_tag_ids"
       )}
    end
  end

  # An omitted argument and an explicit `null` are both "not supplied" for the
  # purpose of this check; `[]` is supplied (it means "clear" on `tag_ids`).
  defp supplied(changeset, argument) do
    case Ash.Changeset.fetch_argument(changeset, argument) do
      {:ok, value} -> value
      :error -> nil
    end
  end
end
