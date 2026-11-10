defmodule KilnCMS.CMS.Changes.StateUnchangedSinceRead do
  @moduledoc """
  A compare-and-swap on `state`: the `UPDATE` matches only a row still in the
  workflow state of the struct the caller holds (#2532).

  `optimistic_lock(:lock_version)` does not cover this on its own, because
  the workflow writes keep `lock_version`: `:publish`, `:publish_scheduled`,
  `:unpublish` and `:unpublish_scheduled` (which fold a working copy into the
  live columns), `:archive` and `:unarchive`. A struct held across one of
  them still passes the lock while its `state` and text no longer describe
  the row. `:restore_version` pairs the two, as `If-Match` pairs
  `{lock_version, state}` (`KilnCMS.CMS.Changes.CheckExpectedVersion`),
  because `RestoreVersion` judges the struct: its state picks the claim and
  alt-text gates and its values decide which force-changes Ash drops.

  A miss raises `Ash.Error.Changes.StaleRecord`, the same error as the lock.
  """
  use Ash.Resource.Change

  require Ash.Expr

  @impl true
  def change(changeset, _opts, _context) do
    read = changeset.data.state
    Ash.Changeset.filter(changeset, Ash.Expr.expr(state == ^read))
  end
end
