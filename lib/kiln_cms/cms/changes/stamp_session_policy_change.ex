defmodule KilnCMS.CMS.Changes.StampSessionPolicyChange do
  @moduledoc """
  Stamps `policy_changed_at` on every save of a `KilnCMS.CMS.SiteSessionPolicy`
  (#2246). Idle time is measured from no earlier than it, so a session that sat
  idle before the timeout was turned on, or shortened, is not signed out the
  moment the admin saves.

  The server's clock: the save is a create (an upsert), which has no SQL
  `now()` to borrow on its insert branch. Node skew moves the grace by the
  skew, never past the timeout itself.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.force_change_attribute(changeset, :policy_changed_at, DateTime.utc_now())
  end
end
