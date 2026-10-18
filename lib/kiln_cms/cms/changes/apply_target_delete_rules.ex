defmodule KilnCMS.CMS.Changes.ApplyTargetDeleteRules do
  @moduledoc """
  On a content record's hard `:purge`, applies the `on_target_delete` rule of
  every `:reference` field that connects other records to it (R5,
  `KilnCMS.CMS.ContentLinks.TargetDelete`): a `:restrict` field refuses the
  purge before anything is deleted, and a `:clear` field's referrers are
  rewritten without it after the row is gone, in the same transaction.

  Not on the soft delete: trash keeps the edges, so a restore needs nothing.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.ContentLinks.TargetDelete

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      case TargetDelete.check_restrict(changeset.data) do
        :ok -> changeset
        {:error, error} -> Ash.Changeset.add_error(changeset, error)
      end
    end)
    |> Ash.Changeset.after_action(fn _changeset, record ->
      case TargetDelete.clear_referrers(record) do
        :ok -> {:ok, record}
        {:error, error} -> {:error, error}
      end
    end)
  end
end
