defmodule KilnCMS.CMS.Changes.UnchangedSinceRead do
  @moduledoc """
  A compare-and-swap on `lock_version`, for a background write that must lose
  to an editor rather than race one — `:refresh_computed`
  (`KilnCMS.CMS.Computed.DailyRefresh`).

  `optimistic_lock(:lock_version)` would also refuse a stale write, but it
  *bumps* the version on success, and an editor with the document open would
  then hit a `StaleRecord` on their next save because a background job ran.
  This only filters the `UPDATE` on the version the caller read: a row an
  editor has saved since matches nothing and the write fails as stale, while
  a successful write leaves the version where it was.
  """
  use Ash.Resource.Change

  require Ash.Expr

  @impl true
  def change(changeset, _opts, _context) do
    read = changeset.data.lock_version
    Ash.Changeset.filter(changeset, Ash.Expr.expr(lock_version == ^read))
  end
end
