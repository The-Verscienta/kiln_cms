defmodule KilnCMS.Backups.DestinationConfig.Changes.KeepUpdatedAt do
  @moduledoc """
  A Test's result is not an edit (#2952): `:record_test_result` leaves
  `updated_at`, the version `Changes.UnchangedSinceRead` compares, where it
  was, so an edit form open on the destination can still be saved after a
  Test.

  An atomic `updated_at = updated_at`: an attribute the changeset already
  changes gets no update default, and the `UPDATE` keeps the row's own
  value rather than one read earlier.
  """
  use Ash.Resource.Change

  require Ash.Expr

  @impl true
  def change(changeset, _opts, _context),
    do: Ash.Changeset.atomic_update(changeset, :updated_at, Ash.Expr.expr(updated_at))
end
