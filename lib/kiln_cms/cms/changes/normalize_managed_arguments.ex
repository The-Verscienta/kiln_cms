defmodule KilnCMS.CMS.Changes.NormalizeManagedArguments do
  @moduledoc """
  De-duplicates relationship id-list arguments before `manage_relationship`
  sees them (#521, generalized in #637).

  A repeated id makes `manage_relationship` try to insert the same join row
  twice, and the unique index rejects the second one — surfacing to the caller
  as `"has already been taken"` on an internal join column the caller never
  sent. "Tag it as Elixir and Elixir", or "relate the same post twice", is
  exactly what an LLM emits, so the repeat is de-duplicated rather than
  reported.

  This is a normalization, not a validation: sending an id twice expresses one
  unambiguous intent, unlike sending it in both the add and remove verbs (which
  `KilnCMS.CMS.Validations.MergeArguments` refuses).

      change {NormalizeManagedArguments,
        arguments: [:tag_ids, :add_tag_ids, :remove_tag_ids]}

  Declared ahead of every `manage_relationship` on the group so each argument is
  normalized on the way in. `nil` is left alone — on a complete-set argument it
  means "clear", which is not the same as `[]` being empty of duplicates.
  """
  use Ash.Resource.Change

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :arguments) do
      {:ok, arguments} when is_list(arguments) and arguments != [] -> {:ok, opts}
      _ -> {:error, ":arguments must be a non-empty list of argument names"}
    end
  end

  @impl true
  def change(changeset, opts, _context),
    do: Enum.reduce(opts[:arguments], changeset, &dedupe(&2, &1))

  defp dedupe(changeset, argument) do
    case Ash.Changeset.fetch_argument(changeset, argument) do
      {:ok, ids} when is_list(ids) ->
        Ash.Changeset.set_argument(changeset, argument, Enum.uniq(ids))

      _ ->
        changeset
    end
  end
end
