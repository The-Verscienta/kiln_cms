defmodule KilnCMS.Backups.DestinationConfig.Changes.UnchangedSinceRead do
  @moduledoc """
  The `:update` action's optimistic lock (#2952): the `UPDATE` matches the
  row only while its `updated_at` is still the one on the record the caller
  read, so a save from a form opened before someone else's change (a rename,
  enabling or disabling, retention) fails as `Ash.Error.Changes.StaleRecord`
  instead of writing over it.

  `updated_at` is the version: every `:update` moves it, and no column is
  needed for it. `:record_test_result` leaves it where it was
  (`Changes.KeepUpdatedAt`), so pressing **Test** doesn't make an open form
  stale.

  A filter rather than `optimistic_lock/1`, which increments its attribute
  and so takes an integer column.
  """
  use Ash.Resource.Change

  require Ash.Expr

  @impl true
  def change(changeset, _opts, _context) do
    read = changeset.data.updated_at
    Ash.Changeset.filter(changeset, Ash.Expr.expr(updated_at == ^read))
  end
end
